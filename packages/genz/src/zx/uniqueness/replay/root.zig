const std = @import("std");
const creating = @import("generated_uniqueness_replay_create");
const columns = @import("zx").columns;
const selecting = @import("generated_uniqueness_replay_select");
const Creation = std.meta.Child(creating.Input);
const PreviousParameter = @typeInfo(@FieldType(Creation, "previous")).optional.child;
const indirect_previous = @typeInfo(PreviousParameter) == .pointer;
const Previous = if (indirect_previous) std.meta.Child(PreviousParameter) else PreviousParameter;
const Self = @This();

active: bool,
changes: []const bool,
cursors: [3][]u32 = @splat(&.{}),
pub fn init(allocator: std.mem.Allocator, previous: anytype, key: [32]u8, identities: []const [32]u8, callees: []const []const u32) std.mem.Allocator.Error!Self {
    var descriptor: Previous = undefined;
    var calls: std.meta.Child(@FieldType(Previous, "callees")) = undefined;

    if (previous) |value| {
        calls = .{ .starts = value.callees.starts, .edges = value.callees.edges };

        descriptor = .{
            .key = &value.key,
            .identities = std.mem.sliceAsBytes(value.identities),
            .callees = &calls,
        };
    }

    const input: Creation = .{
        .previous = if (previous != null) (if (indirect_previous) &descriptor else descriptor) else null,
        .key = &key,
        .identities = std.mem.sliceAsBytes(identities),
        .callees = callees,
    };

    const state = columns.invoke(creating.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .active = state.following, .changes = state.changed };
}

pub fn select(self: *Self, allocator: std.mem.Allocator, comptime kind: anytype, index: usize, starts: []const u32, verify: bool) std.mem.Allocator.Error!@import("../trace.zig").Selection {
    const input: std.meta.Child(selecting.Input) = .{
        .positions = @ptrCast(&self.cursors[@backingInt(kind)]),
        .index = index,
        .starts = starts,
        .changed = self.changes[index],
        .verify = verify,
    };

    const result = columns.invoke(selecting.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .following = result.following, .cursor = result.cursor };
}
