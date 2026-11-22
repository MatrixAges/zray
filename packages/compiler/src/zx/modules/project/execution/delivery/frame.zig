const std = @import("std");
const zx = @import("zx");
const owner = @import("../../../project.zig");
const load = @import("../load.zig");
const input = @import("../../../module_input.zig");
const indexed = @import("../../../parse_cache.zig").indexed_enabled;
const Loading = @import("../../load/host.zig");
const Target = @import("../../target/host.zig");
const ModuleRecord = @import("../../../module_record.zig");
const Self = @This();

const Item = union(enum) {
    native: @TypeOf(owner.import_view.get(@as(zx.syntax.header.Native, undefined), 0)),
    indexed: if (indexed) @TypeOf(owner.import_view.get(@as(input.Indexed, undefined).header(), 0)) else void,
};

walk: *load.Walk,
active: *owner.LoadFrame,
item: Item,
scope: Target.Scope = undefined,
route: Loading.Route = undefined,
duplicate: zx.ast.Name = undefined,
resolved: Target.Resolved = undefined,
source_row: usize = undefined,
imported: owner.Imported = undefined,
dependency: ModuleRecord.Target.Wire = undefined,
identity: ?[]const u8 = null,
path_buffer: [512]u8 = undefined,
path_memory: std.heap.BufferFirstAllocator = undefined,
path_started: bool = false,
pub fn borrow(handle: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn run(walk: *load.Walk, row: usize, completed: ?u64) zx.Error!?u64 {
    const entry = @import("generated_project_import_delivery");
    const Input = std.meta.Child(entry.Input);

    var frame: Self = .{
        .walk = walk,
        .active = walk.active(),
        .item = switch (walk.header) {
            .native => |header| .{ .native = owner.import_view.get(header, row) },
            .indexed => |header| if (indexed) .{ .indexed = owner.import_view.get(header, row) } else unreachable,
        },
    };

    defer if (frame.path_started) {
        _ = walk.paths.reset(.retain_capacity);
    };

    const request: Input = .{ .frame = @ptrCast(&frame), .signature = walk.phase == .signature, .completed = completed };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(empty.allocator(), &request) catch |err| @import("../invoke.zig").errorSet(err);
}
