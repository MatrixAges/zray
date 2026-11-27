const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Topology = @import("../optional/topology.zig").borrowType;
const Solve = @import("../../project/workflow/solve/abi.zig").Solve;
const Replay = std.meta.Child(@FieldType(Solve, "non_null"));

pub const Frame = struct {
    graph: *Graph,
    view: Replay,
    topology: Topology(Replay),
    spans: []const zx.Span,
    pub fn bind(self: *Frame, graph: *Graph) void {
        const projections = graph.pending.nonnull.slice();

        self.graph = graph;
        self.spans = projections.items(.span);

        self.topology.bind(graph);

        self.view = .{
            .frame = @ptrCast(self),
            .graph = &self.topology.graph,
            .parents = @ptrCast(&self.topology.parents),
            .known = &self.topology.known,
            .sources = @ptrCast(projections.items(.source)),
            .values = @ptrCast(projections.items(.value)),
        };
    }

    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn refreshNonNullTopology(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.topology.bind(frame.graph);
}

pub fn registerNonNullPayload(handle: *anyopaque, row: u64, value: u32) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const span = frame.spans[@intCast(row)];

    return @backingInt(try frame.graph.known(@fromBackingInt(value), span));
}

pub fn reserveNonNullSource(handle: *anyopaque, row: u64, payload: u32) std.mem.Allocator.Error!u32 {
    const frame = Frame.borrow(handle);

    const created = Nodes.append(frame.graph, .{ .optional = @fromBackingInt(payload) }, frame.spans[@intCast(row)]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return @backingInt(created);
}

pub fn mergeNonNullProjection(handle: *anyopaque, row: u64, left: u32, right: u32) zx.Error!void {
    const frame = Frame.borrow(handle);

    try frame.graph.unify(@fromBackingInt(left), @fromBackingInt(right), frame.spans[@intCast(row)]);
}
