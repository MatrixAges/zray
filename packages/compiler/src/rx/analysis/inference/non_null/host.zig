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
            .graph = &self.topology.graph,
            .parents = self.topology.parents,
            .known = &self.topology.known,
            .sources = @ptrCast(projections.items(.source)),
            .values = @ptrCast(projections.items(.value)),
        };
    }
    pub fn refresh(frame: *Frame) void {
        frame.topology.bind(frame.graph);
        frame.view.parents = frame.topology.parents;
    }
    pub fn register(frame: *Frame, row: usize, value: u32) zx.Error!u32 {
        return @backingInt(try frame.graph.known(@fromBackingInt(value), frame.spans[row]));
    }

    pub fn reserve(frame: *Frame, row: usize, payload: u32) std.mem.Allocator.Error!u32 {
        const created = Nodes.append(frame.graph, .{ .optional = @fromBackingInt(payload) }, frame.spans[row]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        return @backingInt(created);
    }
    pub fn merge(frame: *Frame, row: usize, left: u32, right: u32) zx.Error!void {
        try frame.graph.unify(@fromBackingInt(left), @fromBackingInt(right), frame.spans[row]);
    }
};
