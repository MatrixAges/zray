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

work: Plan.Work,
first: Commit.Constraints,
second: Commit.Constraints,
shape: Nodes.Encoded,
left: []const u32 = &.{},
right: []const u32 = &.{},
fields: Fields.Alignment = .{},
position: u64 = 0,
pub fn admit(self: *Self, graph: *const Graph, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    const work = self.work;
    const members = graph.nodes.items(.members);
    const declared = &graph.types.items;

    switch (work.action) {
        .Child, .KnownChild => {},
        .Tuple => {
            self.left = members[work.left_operand];
            self.right = members[work.right_operand];
        },
        .KnownTuple => {
            self.left = members[work.left_operand];
            self.right = declared.children.items[work.right_operand..][0..work.right_size];
        },
        .Object => {
            self.left = members[work.left_operand];
            self.right = members[work.right_operand];

            const left = Graph.Fields.fromValues(@ptrCast(self.left));
            const right = Graph.Fields.fromValues(@ptrCast(self.right));

            self.fields = try Fields.alignFields(allocator, left.names(), right.names(), false);
        },
        .KnownObject => {
            self.left = members[work.left_operand];

            const inferred = Graph.Fields.fromValues(@ptrCast(self.left));
            const names = declared.field_names.items[work.right_operand..][0..work.right_size];
            self.right = declared.field_types.items[work.right_operand..][0..work.right_size];
            self.fields = try Fields.alignFields(allocator, names, inferred.names(), true);
        },
        .Adopt => unreachable,
    }
}

pub fn release(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.fields.positions);
}

pub fn next(self: *Self, graph: *const Graph) Transition {
    const KnownTypes = std.meta.Child(@FieldType(Input, "known"));
    const known = graph.pending.known_types.borrow(KnownTypes);

    const input: Input = .{
        .pair = &.{
            .action = self.work.action,
            .position = self.position,
            .left_operand = self.work.left_operand,
            .right_operand = self.work.right_operand,
            .left = self.left,
            .right = self.right,
            .positions = self.fields.positions[0..self.fields.scanned],
        },
        .known = &known,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const transition = zx.columns.invoke(advance.executeValue, empty.allocator(), &input) catch unreachable;

    self.position = transition.position;

    return transition;
}

pub fn finish(self: *Self, graph: *Graph, span: zx.Span) zx.Error!void {
    if (self.work.action == .Object) {
        const left = Graph.Fields.fromValues(@ptrCast(self.left));
        const right = Graph.Fields.fromValues(@ptrCast(self.right));
        const published = try Fields.publish(graph.allocator, left, right, self.fields);

        self.shape.members = @ptrCast(published.values());
    }

    try Commit.publish(graph, self.work.left, self.work.right, self.first, self.second, self.shape, span);
}
