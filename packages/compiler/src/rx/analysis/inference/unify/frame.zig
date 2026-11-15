const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Plan = @import("../unification/plan.zig");
const Fields = @import("../unification/fields.zig");
const Commit = @import("../unification/commit.zig");
const Self = @This();
const advance = @import("generated_rx_unification_advance");
const Input = std.meta.Child(advance.Input);
const Transition = @typeInfo(@typeInfo(@TypeOf(advance.executeValue)).@"fn".return_type.?).error_union.payload;

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

pub fn next(self: *Self, graph: *const Graph, depth: usize) Transition {
    const KnownTypes = std.meta.Child(@FieldType(Input, "known"));
    const known = graph.pending.known_types.borrow(KnownTypes);
    const parents = graph.parents();

    const input: Input = .{
        .pair = &.{
            .action = self.action,
            .position = self.position,
            .left_operand = self.left_operand,
            .right_operand = self.right_operand,
            .left_members = self.left_members,
            .right_members = self.right_members,
            .positions = self.fields.positions[0..self.fields.scanned],
        },
        .known = &known,
        .parents = @ptrCast(&parents),
        .depth = depth,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const transition = zx.columns.invoke(advance.executeValue, empty.allocator(), &input) catch unreachable;

    self.position = transition.position;

    return transition;
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
