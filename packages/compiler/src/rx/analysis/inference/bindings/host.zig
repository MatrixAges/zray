const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const rules = @import("rules.zig");
const Solve = @import("../../project/workflow/solve/abi.zig").Solve;
const Replay = std.meta.Child(@FieldType(Solve, "bindings"));
const Topology = std.meta.Child(@FieldType(Replay, "topology"));
const View = std.meta.Child(@FieldType(Topology, "graph"));
const Collisions = std.meta.Child(@FieldType(Replay, "collisions"));
const errors = @import("../../project/workflow/errors.zig");
const require_rule = @import("generated_rx_require_binding_value");
const Requirement = std.meta.Child(require_rule.Input);

pub const Frame = struct {
    graph: *Graph,
    view: Replay,
    topology: Topology,
    nodes: View,
    collisions: Collisions,
    collision_spans: []const zx.Span,
    lookup_spans: []const zx.Span,
    use_spans: []const zx.Span,
    pub fn bind(self: *Frame, graph: *Graph) void {
        const pending = &graph.pending;
        const collisions = pending.binding_collisions.slice();
        const lookups = pending.binding_lookups.slice();
        const uses = pending.value_uses.slice();

        self.graph = graph;

        self.bindTopology();

        self.collision_spans = collisions.items(.span);
        self.lookup_spans = lookups.items(.span);
        self.use_spans = uses.items(.span);

        self.collisions = .{
            .left = @ptrCast(collisions.items(.left)),
            .right = @ptrCast(collisions.items(.right)),
            .messages = collisions.items(.message),
        };

        self.view = .{
            .topology = &self.topology,
            .collisions = &self.collisions,
            .candidates = @ptrCast(lookups.items(.candidates)),
            .values = @ptrCast(lookups.items(.value)),
            .uses = @ptrCast(uses.items(.value)),
        };
    }
    fn bindTopology(self: *Frame) void {
        self.nodes = rules.view(Topology, self.graph);
        self.topology = .{ .graph = &self.nodes, .parents = self.graph.parents() };
    }

    pub fn refresh(self: *Frame) void {
        self.bindTopology();
    }
    pub fn unify(self: *Frame, row: usize, value: u32) zx.Error!void {
        try self.graph.unify(@fromBackingInt(self.view.values[row]), @fromBackingInt(value), self.lookup_spans[row]);
    }
    pub fn reject(self: *Frame, diagnostic: anytype) zx.Error {
        const spans = switch (diagnostic.source) {
            .Collision => self.collision_spans,
            .Lookup => self.lookup_spans,
            .Use => self.use_spans,
        };

        return self.graph.reporter.fail(.name, spans[@intCast(diagnostic.row)], diagnostic.message);
    }
};

pub fn require(graph: *Graph, value: Graph.Id, span: zx.Span) zx.Error!void {
    const RequireTopology = std.meta.Child(@FieldType(Requirement, "topology"));

    const input: Requirement = .{
        .topology = &.{ .graph = &rules.view(RequireTopology, graph), .parents = graph.parents() },
        .value = @backingInt(value),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(require_rule.executeValue, empty.allocator(), &input) catch |err| return errors.errorSet(err);

    if (result.message) |message| return graph.reporter.fail(.name, span, message);
    if (result.pending) try graph.pending.value_uses.append(graph.pending.allocator, .{ .value = value, .span = span });
}
