const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Topology = @import("../optional/topology.zig").borrowType;
const Solve = @import("../../project/workflow/solve/abi.zig").Solve;
const Replay = std.meta.Child(@FieldType(Solve, "non_null"));
const Node = std.meta.Child(@FieldType(Replay, "node"));

pub const Frame = struct {
    graph: *Graph,
    view: Replay,
    topology: Topology(Replay),
    spans: []const zx.Span,
    revision: []u64,
    node: Node,
    append: Nodes.Append(Node),
    pub fn bind(self: *Frame, graph: *Graph) void {
        const projections = graph.pending.nonnull.slice();

        self.graph = graph;
        self.spans = projections.items(.span);
        self.revision = (&graph.revision)[0..1];

        self.topology.bind(graph);

        self.view = .{
            .frame = @ptrCast(self),
            .graph = &self.topology.graph,
            .parents = @ptrCast(&self.topology.parents),
            .known = &self.topology.known,
            .sources = @ptrCast(projections.items(.source)),
            .values = @ptrCast(projections.items(.value)),
            .node = &self.node,
            .revision = @ptrCast(&self.revision),
        };
    }

    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn refreshNonNullTopology(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.topology.bind(frame.graph);
}

pub fn registerNonNullPayload(handle: *const anyopaque, row: u64, value: u32) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const span = frame.spans[@intCast(row)];

    return @backingInt(try frame.graph.known(@fromBackingInt(value), span));
}

pub fn reserveNonNullSource(handle: *const anyopaque, row: u64, payload: u32) std.mem.Allocator.Error!u32 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const reservation = try Nodes.reserve(graph, 1);

    frame.append.bind(&frame.node, graph, reservation, .{ .optional = @fromBackingInt(payload) }, frame.spans[@intCast(row)]);

    return @intCast(reservation.first);
}

pub fn mergeNonNullProjection(handle: *const anyopaque, row: u64, left: u32, right: u32) zx.Error!void {
    const frame = Frame.borrow(handle);

    try frame.graph.unify(@fromBackingInt(left), @fromBackingInt(right), frame.spans[@intCast(row)]);
}
