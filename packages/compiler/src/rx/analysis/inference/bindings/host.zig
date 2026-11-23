const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const rules = @import("rules.zig");
const Solve = @import("../../project/workflow/solve/abi.zig").Solve;
const Replay = std.meta.Child(@FieldType(Solve, "bindings"));
const Topology = std.meta.Child(@FieldType(Replay, "topology"));
const View = std.meta.Child(@FieldType(Topology, "graph"));
const Collisions = std.meta.Child(@FieldType(Replay, "collisions"));
const Uses = std.meta.Child(@FieldType(Replay, "uses"));

pub const Frame = struct {
    graph: *Graph,
    view: Replay,
    topology: Topology,
    nodes: View,
    parents: []u32,
    collisions: Collisions,
    uses: Uses,
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

        self.topology = .{ .graph = &self.nodes, .parents = @ptrCast(&self.parents) };
        self.collision_spans = collisions.items(.span);
        self.lookup_spans = lookups.items(.span);
        self.use_spans = uses.items(.span);

        self.collisions = .{
            .left = @ptrCast(collisions.items(.left)),
            .right = @ptrCast(collisions.items(.right)),
            .spans = @ptrCast(&self.collision_spans),
            .messages = collisions.items(.message),
        };

        self.uses = .{
            .values = @ptrCast(uses.items(.value)),
            .spans = @ptrCast(&self.use_spans),
        };

        self.view = .{
            .frame = @ptrCast(self),
            .reporter = @ptrCast(graph.reporter),
            .topology = &self.topology,
            .collisions = &self.collisions,
            .candidates = @ptrCast(lookups.items(.candidates)),
            .values = @ptrCast(lookups.items(.value)),
            .lookup_spans = @ptrCast(&self.lookup_spans),
            .uses = &self.uses,
        };
    }
    fn bindTopology(self: *Frame) void {
        self.nodes = rules.view(Topology, self.graph);
        self.parents = self.graph.parents();
    }

    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn refreshBindingTopology(handle: *const anyopaque) void {
    Frame.borrow(handle).bindTopology();
}

pub fn unifyBindingReplay(handle: *const anyopaque, index: u64, value: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const row: usize = @intCast(index);

    try frame.graph.unify(@fromBackingInt(frame.view.values[row]), @fromBackingInt(value), frame.lookup_spans[row]);
}

pub fn reportBindingName(handle: *const anyopaque, source: *const anyopaque, row: u64, message: []const u8) zx.Error!void {
    const reporter: *zx.Reporter = @ptrCast(@alignCast(@constCast(handle)));
    const spans: *const []const zx.Span = @ptrCast(@alignCast(source));

    return reporter.fail(.name, spans.*[@intCast(row)], message);
}
