const std = @import("std");
const Graph = @import("../../types.zig");
const Topology = @import("../../optional/topology.zig").borrowType;
const Solve = @import("../../../project/workflow/solve/abi.zig").Solve;
const Request = child(Solve, "assignments");
const View = child(Request, "view");
const Validation = child(Solve, "validation");
const Rows = child(Request, "rows");
const Sequences = child(Request, "sequences");

pub const Frame = struct {
    graph: *Graph,
    view: Request,
    validation: Validation,
    validation_columns: child(Validation, "columns"),
    topology: Topology(View),
    merge_view: View,
    nodes: child(Request, "nodes"),
    edges: child(Rows, "edges"),
    rows: Rows,
    sequences: Sequences,
    sequence_rows: child(Sequences, "sequence"),
    indexes: child(Request, "indexes"),
    pub fn bind(self: *Frame, graph: *Graph) void {
        self.graph = graph;

        self.refresh();

        const edges = graph.pending.assignments.slice();

        self.edges = .{
            .left = @ptrCast(edges.items(.value)),
            .right = @ptrCast(edges.items(.expected)),
        };

        self.rows = .{ .edges = &self.edges, .spans = .Assignment };

        const sequences = graph.pending.sequences.slice();

        self.sequence_rows = .{ .values = @ptrCast(sequences.items(.value)), .elements = @ptrCast(sequences.items(.elements)) };
        self.sequences.sequence = &self.sequence_rows;
        self.sequences.spans = .Sequence;

        const indexes = graph.pending.indexes.slice();

        self.indexes = .{ .values = @ptrCast(indexes.items(.value)), .resolved = indexes.items(.resolved) };

        self.view = .{
            .view = &self.merge_view,
            .nodes = &self.nodes,
            .rows = &self.rows,
            .sequences = &self.sequences,
            .indexes = &self.indexes,
            .node_spans = .Node,
        };
    }

    pub fn bindValidation(self: *Frame, graph: *Graph, resolver: @FieldType(Validation, "resolver")) void {
        const edges = graph.pending.assignments.slice();

        self.topology.bind(graph);

        self.validation_columns = .{
            .graph = &self.topology.graph,
            .left = @ptrCast(edges.items(.value)),
            .right = @ptrCast(edges.items(.expected)),
            .parents = self.topology.parents,
        };

        self.validation = .{
            .resolver = resolver,
            .spans = .Assignment,
            .columns = &self.validation_columns,
        };
    }

    pub fn refresh(self: *Frame) void {
        const rows = self.graph.nodes.slice();

        self.topology.bind(self.graph);

        self.nodes = .{ .kinds = self.topology.graph.kinds, .allowed = rows.items(.allowed) };
        self.sequences.members = rows.items(.members);

        self.merge_view = .{
            .graph = &self.topology.graph,
            .parents = self.topology.parents,
            .known = &self.topology.known,
            .allowed = self.nodes.allowed,
        };
    }
};

fn child(comptime T: type, comptime field: []const u8) type {
    return std.meta.Child(@FieldType(T, field));
}
