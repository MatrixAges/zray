const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Analysis = @import("../../../analysis/analyze.zig");
const Validate = @import("../../../ir/validate.zig");
const publication = @import("../publication/host.zig");
const functions = @import("../../function_body.zig");
const cache_publication = @import("../../semantic_cache/publication.zig");
const generated = @import("parser_options").generated_parser;
const Status = if (generated) @import("project_execution_abi").layouts.@"zig:project_host".CacheWrite else cache_publication.Status;

const Entry = struct {
    project: *Project,
    root: usize,
    scratch: zx.Arena,
    result: Analysis.Result = undefined,
    fn borrow(handle: *const anyopaque) *Entry {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(project: *Project, root: usize) std.mem.Allocator.Error!Analysis.Result {
    var state: Entry = .{ .project = project, .root = root, .scratch = .init(project.arena.child_allocator) };

    defer state.scratch.deinit();
    prepare(&state);

    if (comptime generated) {
        const entry = @import("generated_project_execute_entry");
        const unit = &project.units[root];
        const program = &state.result.value.ir;
        const linked = project.functions.view();
        const member = if (program.type_only) unit.function else null;
        const row = if (member) |id| @backingInt(id) else null;
        const expressions = if (row) |index| linked.expressions[index] else &program.expressions;
        const records = project.cache_records.items;

        const record_column: zx.memory.ReadColumn = .{
            .bytes = std.mem.sliceAsBytes(records),
            .count = records.len,
            .stride = @sizeOf(usize),
            .offset = 0,
        };

        const verified: zx.memory.ColumnLengths = &.{&project.verified.functions};
        const uncacheable: zx.memory.ColumnLengths = if (project.semantic_cache) |cache| &.{&cache.uncacheable} else &.{};

        const input: std.meta.Child(entry.Input) = .{
            .entry = @ptrCast(&state),
            .plan = &.{
                .type_only = program.type_only,
                .own = if (unit.function) |id| @backingInt(id) else null,
                .native = if (row) |index| linked.native_modules[index] != null else false,
                .linked_count = linked.count(),
                .calls = expressions.call_functions,
            },
            .verified = @ptrCast(&verified),
            .records = @ptrCast(&record_column),
            .record_count = records.len,
            .uncacheable = @ptrCast(&uncacheable),
            .root = if (project.cache_root) |cache_row| cache_row else null,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        _ = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
    } else {
        try seed(&state);
    }

    return state.result;
}

fn seed(state: *Entry) std.mem.Allocator.Error!void {
    const project = state.project;
    const unit = &project.units[state.root];
    const published = try publication.publishSeedEntry(project.allocator, &state.result.value.ir, unit.function, project.functions.view());

    state.result.entry_function = published.recursive;
    project.verified.functions = @min(published.visible_count, project.verified.functions);

    if (!try validateProjectEntry(state)) return;

    for (project.cache_records.items) |index| {
        switch (try storeProjectRecord(state, index, project.cache_root == index)) {
            .Stored => {},
            .MissingOrigin => project.semantic_cache.?.uncacheable += 1,
            .Invalid => return,
        }
    }
}

fn prepare(entry: *Entry) void {
    const project = entry.project;
    const unit = &project.units[entry.root];
    var program = project.entry_program.?;
    program.types = project.types.view();
    program.exports = unit.exports;
    program.constant_exports = unit.constants;
    program.native_modules = project.native_modules.view();

    entry.result = .{
        .arena = undefined,
        .value = .{ .ir = program },
        .nominal_types = project.nominal_origins.items.view(),
        .modules = project.modules.items,
        .store_initializers = project.store_initializers.items,
    };
}

pub fn installProjectEntryBody(handle: *const anyopaque, row: u32) void {
    const entry = Entry.borrow(handle);
    const body = entry.project.functions.view().at(row);

    publication.installBody(&entry.result.value.ir, body);
}

pub fn exposeProjectEntryFunctions(handle: *const anyopaque, count: u64) void {
    const entry = Entry.borrow(handle);
    entry.result.value.ir.functions = entry.project.functions.view().prefix(@intCast(count));
}

pub fn forwardProjectNativeEntry(handle: *const anyopaque, row: u32) std.mem.Allocator.Error!void {
    const entry = Entry.borrow(handle);

    try functions.externalEntry(entry.project.allocator, &entry.result.value.ir, @fromBackingInt(row));
}

pub fn forwardProjectRecursiveEntry(handle: *const anyopaque, row: u32) std.mem.Allocator.Error!void {
    const entry = Entry.borrow(handle);
    const id: zx.ir.FunctionId = @fromBackingInt(row);

    try functions.entry(entry.project.allocator, &entry.result.value.ir, id);

    entry.result.entry_function = id;
}

pub fn validateProjectEntry(handle: *const anyopaque) std.mem.Allocator.Error!bool {
    const entry = Entry.borrow(handle);
    const project = entry.project;

    entry.result.arena = project.arena.*;

    if (try Validate.validateProjectPrefix(project.arena.child_allocator, entry.result.value.ir, project.verified)) |issue| {
        entry.result = .{ .arena = project.arena.*, .value = .{ .diagnostic = issue } };

        return false;
    }

    return true;
}

pub fn storeProjectRecord(handle: *const anyopaque, index: u64, root: bool) std.mem.Allocator.Error!Status {
    const entry = Entry.borrow(handle);
    const project = entry.project;
    const status = try cache_publication.store(project.semantic_cache.?, &entry.scratch, &entry.result, @intCast(index), root, &project.cache_context);

    if (status == .Invalid) entry.result = .{ .arena = project.arena.*, .value = .{ .diagnostic = cache_publication.invalid } };

    return @fromBackingInt(@intCast(@backingInt(status)));
}
