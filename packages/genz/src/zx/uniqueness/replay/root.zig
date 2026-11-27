const std = @import("std");
const creating = @import("generated_uniqueness_replay_create");
const columns = @import("zx").columns;
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

pub fn visit(self: *Self, comptime View: type, comptime kind: anytype, index: usize, starts: []const u32, verify: bool) View {
    return .{
        .positions = &self.cursors[@backingInt(kind)],
        .index = index,
        .starts = starts,
        .changed = self.changes[index],
        .verify = verify,
    };
}

pub const Visit = struct {
    positions: *[]u32,
    index: usize,
    starts: []const u32,
    changed: bool,
    verify: bool,
    pub fn input(self: Visit, comptime View: type) View {
        return .{
            .positions = self.positions.*,
            .index = self.index,
            .starts = self.starts,
            .changed = self.changed,
            .verify = self.verify,
        };
    }
    pub fn advance(self: Visit, allocator: std.mem.Allocator, next: ?u32) std.mem.Allocator.Error!void {
        const position = next orelse return;

        if (self.positions.*.len == 0) {
            self.positions.* = try allocator.dupe(u32, self.starts[0 .. self.starts.len - 1]);
        }

        self.positions.*[self.index] = position;
    }
};
