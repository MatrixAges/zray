const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Plan = @import("../unification/plan.zig");
const Fields = @import("../unification/fields.zig");
const Commit = @import("../unification/commit.zig");
const Self = @This();

parent: Graph.Id,
child: Graph.Id,
action: Plan.Action,
left_operand: u32,
right_operand: u32,
first: Commit.Constraints,
second: Commit.Constraints,
shape: Nodes.Encoded,
left_members: []const u32,
right_members: []const u32,
fields: Fields.Alignment = .{},
position: u64 = 0,
pub fn alignFields(self: *Self, declared_names: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    switch (self.action) {
        .Child, .KnownChild, .Tuple, .KnownTuple => {},
        .Object => {
            const left = Graph.Fields.fromValues(@ptrCast(self.left_members));
            const right = Graph.Fields.fromValues(@ptrCast(self.right_members));

            self.fields = try Fields.alignFields(allocator, left.names(), right.names(), false);
        },
        .KnownObject => {
            const inferred = Graph.Fields.fromValues(@ptrCast(self.left_members));

            self.fields = try Fields.alignFields(allocator, declared_names, inferred.names(), true);
        },
        .Adopt => unreachable,
    }
}

pub fn release(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.fields.positions);
}

pub fn finish(self: *Self, graph: *Graph, span: zx.Span) zx.Error!void {
    if (self.action == .Object) {
        const left = Graph.Fields.fromValues(@ptrCast(self.left_members));
        const right = Graph.Fields.fromValues(@ptrCast(self.right_members));
        const published = try Fields.publish(graph.allocator, left, right, self.fields);

        self.shape.members = @ptrCast(published.values());
    }

    try Commit.publish(graph, self.parent, self.child, self.first, self.second, self.shape, span);
}
