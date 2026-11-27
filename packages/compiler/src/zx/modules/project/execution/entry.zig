const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Analysis = @import("../../../analysis/analyze.zig");
const Validate = @import("../../../ir/validate.zig");
const publication = @import("../publication/host.zig");
const cache_publication = @import("../../semantic_cache/publication.zig");
const generated = @import("parser_options").generated_parser;
const cache_entries = @import("../../semantic_cache/entries.zig");
const Artifact = @import("../../artifact/extract.zig");
const ABI = @import("project_execution_abi").layouts.@"zig:project_host";

const Entry = struct {
    project: *Project,
    root: usize,
    scratch: zx.Arena,
    result: Analysis.Result = undefined,
    pending: ?cache_entries.Pending = null,
    fn borrow(handle: *anyopaque) *Entry {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(project: *Project, root: usize) std.mem.Allocator.Error!Analysis.Result {
    var state: Entry = .{ .project = project, .root = root, .scratch = .init(project.arena.child_allocator) };

    defer state.scratch.deinit();

    errdefer if (state.pending) |*slot| {
        slot.cancel();
        if (slot.value) |*value| value.result.deinit();
    };

    prepare(&state);

    if (comptime generated) {
        const entry = @import("generated_project_execute_entry");
        const unit = &project.units[root];
        const program = &state.result.value.ir;
        program.functions = project.functions.view();

        const Input = std.meta.Child(entry.Input);
        const Publication = std.meta.Child(@FieldType(Input, "publication"));
        const Original = std.meta.Child(@FieldType(Publication, "original"));
        const functions = zx.columns.view(std.meta.Child(@FieldType(Publication, "functions")), &program.functions);
        const symbols = zx.columns.pointer(@FieldType(Original, "symbols"), @as(*const zx.ir.SymbolTable, &program.symbols));
        const length_slots = zx.memory.borrowSliceLengths(&program.functions);
        const lengths: zx.memory.ColumnLengths = &length_slots;
        const records = project.cache_records.items;

        const record_column: zx.memory.ReadColumn = .{
            .bytes = std.mem.sliceAsBytes(records),
            .count = records.len,
            .stride = @sizeOf(usize),
            .offset = 0,
        };

        const verified: zx.memory.ColumnLengths = &.{&project.verified.functions};
        const uncacheable: zx.memory.ColumnLengths = if (project.semantic_cache) |cache| &.{&cache.uncacheable} else &.{};

        const input: Input = .{
            .entry = @ptrCast(&state),
            .publication = &.{
                .program = @ptrCast(program),
                .functions = &functions,
                .lengths = @ptrCast(&lengths),
                .linked_count = program.functions.count(),
                .original = &.{
                    .file = program.file_name,
                    .type_only = program.type_only,
                    .own = if (unit.function) |id| @backingInt(id) else null,
                    .input_type = @backingInt(program.input_type),
                    .output_type = @backingInt(program.output_type),
                    .symbols = symbols,
                    .calls = program.expressions.call_functions,
                },
            },
            .verified = @ptrCast(&verified),
            .cache = &.{
                .entry = @ptrCast(&state),
                .records = @ptrCast(&record_column),
                .record_count = records.len,
                .uncacheable = @ptrCast(&uncacheable),
                .root = if (project.cache_root) |cache_row| cache_row else null,
                .root_digest = &project.cache_context.root,
                .dependency_digest = &project.cache_context.dependency,
            },
        };

        const StoreState = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));

        const StoreHost = struct {
            result: *Analysis.Result,
            store_0: *StoreState,
            pub fn commit(self: *@This(), pending: anytype) error{}!void {
                if (pending.store_0) |next| {
                    self.store_0.* = next;

                    if (next.has_recursive) self.result.entry_function = @fromBackingInt(next.recursive);
                }
            }
        };

        var store_value: std.meta.Child(StoreState) = .{ .has_recursive = false, .recursive = 0 };
        var store_ptr: StoreState = &store_value;
        var host: StoreHost = .{ .result = &state.result, .store_0 = &store_ptr };

        _ = entry.executeIn(project.allocator, &input, &host) catch |err| return switch (err) {
            error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
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
        const cache = project.semantic_cache.?;
        const status = try cache_publication.storeSeed(cache, &state.scratch, &state.result, index, project.cache_root == index, &project.cache_context);

        switch (status) {
            .Stored => {},
            .MissingOrigin => cache.uncacheable += 1,
            .Invalid => {
                rejectProjectCacheArtifact(state);

                return;
            },
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

pub fn validateProjectEntry(handle: *anyopaque) std.mem.Allocator.Error!bool {
    const entry = Entry.borrow(handle);
    const project = entry.project;

    entry.result.arena = project.arena.*;

    if (try Validate.validateProjectPrefix(project.arena.child_allocator, entry.result.value.ir, project.verified)) |issue| {
        entry.result = .{ .arena = project.arena.*, .value = .{ .diagnostic = issue } };

        return false;
    }

    return true;
}

pub fn extractProjectCacheArtifact(handle: *anyopaque, row: u64) std.mem.Allocator.Error!ABI.CacheWrite {
    const entry = Entry.borrow(handle);
    const cache = entry.project.semantic_cache.?;
    const index: usize = @intCast(row);

    defer entry.scratch.reset(std.math.maxInt(usize));

    const artifact = Artifact.validated(cache.allocator, entry.scratch.allocator(), &entry.result, entry.result.modules[index]) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingNominalOrigin => .MissingOrigin,
        error.InvalidAnalysis, error.InvalidModule, error.InvalidIr => .Invalid,
    };

    entry.pending = .{
        .allocator = cache.allocator,
        .entries = &cache.entries,
        .value = .{ .result = artifact, .context_digest = undefined },
    };

    return .Ready;
}

pub fn projectCacheSlot(handle: *anyopaque, digest: []const u8) *ABI.CacheSlot {
    const slot = &Entry.borrow(handle).pending.?;
    slot.value.?.context_digest = digest[0..slot.value.?.context_digest.len].*;

    return @ptrCast(slot);
}

pub fn rejectProjectCacheArtifact(handle: *anyopaque) void {
    const entry = Entry.borrow(handle);

    entry.result = .{ .arena = entry.project.arena.*, .value = .{ .diagnostic = cache_publication.invalid } };
}
