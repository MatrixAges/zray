const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Analysis = @import("../../../analysis/analyze.zig");
const Validate = @import("../../../ir/validate.zig");
const publication = @import("../publication/host.zig");
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

    if (comptime generated) {
        const entry = @import("generated_project_execute_entry");

        const input: std.meta.Child(entry.Input) = .{
            .entry = @ptrCast(&state),
            .verified = project.verified.functions,
            .records = project.cache_records.items.len,
            .root = if (project.cache_root) |row| row else null,
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
    const visible = try prepareProjectEntry(state);

    if (!try validateProjectEntry(state, @min(visible, project.verified.functions))) return;

    for (project.cache_records.items) |index| {
        switch (try storeProjectRecord(state, index, project.cache_root == index)) {
            .Stored => {},
            .MissingOrigin => recordMissingOrigin(state),
            .Invalid => return,
        }
    }
}

pub fn prepareProjectEntry(handle: *const anyopaque) std.mem.Allocator.Error!u64 {
    const entry = Entry.borrow(handle);
    const project = entry.project;
    const unit = &project.units[entry.root];
    var program = project.entry_program.?;
    program.types = project.types.view();
    program.exports = unit.exports;
    program.constant_exports = unit.constants;
    program.native_modules = project.native_modules.view();
    const published = try publication.publishEntry(project.allocator, &program, unit.function, project.functions.view());

    entry.result = .{
        .arena = project.arena.*,
        .value = .{ .ir = program },
        .nominal_types = project.nominal_origins.items.view(),
        .modules = project.modules.items,
        .store_initializers = project.store_initializers.items,
        .entry_function = published.recursive,
    };

    return published.visible_count;
}

pub fn validateProjectEntry(handle: *const anyopaque, prefix: u64) std.mem.Allocator.Error!bool {
    const entry = Entry.borrow(handle);
    const project = entry.project;

    project.verified.functions = @intCast(prefix);

    if (try Validate.validateProjectPrefix(project.arena.child_allocator, entry.result.value.ir, project.verified)) |issue| {
        entry.result = .{ .arena = project.arena.*, .value = .{ .diagnostic = issue } };

        return false;
    }

    return true;
}

pub fn projectCacheRecord(handle: *const anyopaque, position: u64) u64 {
    return Entry.borrow(handle).project.cache_records.items[@intCast(position)];
}

pub fn storeProjectRecord(handle: *const anyopaque, index: u64, root: bool) std.mem.Allocator.Error!Status {
    const entry = Entry.borrow(handle);
    const project = entry.project;
    const status = try cache_publication.store(project.semantic_cache.?, &entry.scratch, &entry.result, @intCast(index), root, &project.cache_context);

    if (status == .Invalid) entry.result = .{ .arena = project.arena.*, .value = .{ .diagnostic = cache_publication.invalid } };

    return @enumFromInt(@intFromEnum(status));
}

pub fn recordMissingOrigin(handle: *const anyopaque) void {
    Entry.borrow(handle).project.semantic_cache.?.uncacheable += 1;
}
