const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const Known = @import("../../known.zig");
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
    node_spans: []const zx.Span,
    edges: child(Rows, "edges"),
    rows: Rows,
    left: []u32,
    right: []u32,
    spans: []const zx.Span,
    remaining: u64,
    sequences: Sequences,
    sequence_rows: child(Sequences, "sequence"),
    sequence_spans: []const zx.Span,
    indexes: child(Request, "indexes"),
    pub fn bind(self: *Frame, graph: *Graph, _: *std.heap.ArenaAllocator) void {
        self.graph = graph;

        self.refresh();

        const edges = graph.pending.assignments.slice();

        self.left = @ptrCast(edges.items(.value));
        self.right = @ptrCast(edges.items(.expected));
        self.spans = edges.items(.span);
        self.edges = .{ .left = self.left, .right = self.right };
        self.rows = .{ .edges = &self.edges, .spans = @ptrCast(&self.spans) };

        const sequences = graph.pending.sequences.slice();

        self.sequence_rows = .{ .values = @ptrCast(sequences.items(.value)), .elements = @ptrCast(sequences.items(.elements)) };
        self.sequence_spans = sequences.items(.span);
        self.sequences.sequence = &self.sequence_rows;
        self.sequences.spans = @ptrCast(&self.sequence_spans);

        const indexes = graph.pending.indexes.slice();

        self.indexes = .{ .values = @ptrCast(indexes.items(.value)), .resolved = indexes.items(.resolved) };

        self.view = .{
            .frame = @ptrCast(self),
            .owner = @ptrCast(graph),
            .view = &self.merge_view,
            .nodes = &self.nodes,
            .rows = &self.rows,
            .sequences = &self.sequences,
            .indexes = &self.indexes,
            .node_spans = @ptrCast(&self.node_spans),
        };
    }

    pub fn bindValidation(self: *Frame, graph: *Graph, handle: *anyopaque, resolver: @FieldType(Validation, "resolver")) void {
        const edges = graph.pending.assignments.slice();

        self.spans = edges.items(.span);

        self.topology.bind(graph);

        self.validation_columns = .{
            .graph = &self.topology.graph,
            .left = @ptrCast(edges.items(.value)),
            .right = @ptrCast(edges.items(.expected)),
            .parents = @ptrCast(&self.topology.parents),
        };

        self.validation = .{
            .frame = @ptrCast(handle),
            .resolver = resolver,
            .owner = @ptrCast(graph),
            .spans = @ptrCast(&self.spans),
            .columns = &self.validation_columns,
        };
    }
    fn refresh(self: *Frame) void {
        const rows = self.graph.nodes.slice();

        self.topology.bind(self.graph);

        self.node_spans = rows.items(.span);
        self.nodes = .{ .kinds = self.topology.graph.kinds, .allowed = rows.items(.allowed) };
        self.sequences.members = rows.items(.members);

        self.merge_view = .{
            .graph = &self.topology.graph,
            .parents = @ptrCast(&self.topology.parents),
            .known = &self.topology.known,
            .allowed = self.nodes.allowed,
        };
    }

    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

fn child(comptime T: type, comptime field: []const u8) type {
    return std.meta.Child(@FieldType(T, field));
}

pub fn assignmentRevision(handle: *anyopaque) u64 {
    return Frame.borrow(handle).graph.revision;
}

pub fn assignmentNodeCount(handle: *anyopaque) u64 {
    return Frame.borrow(handle).graph.nodes.len;
}

pub fn registerAssignmentPayload(handle: *anyopaque, node: u32, value: u32, remaining: u64) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const registered = try Known.registerPayload(frame.graph, value, remaining, frame.node_spans[node]);

    frame.remaining = registered.remaining;

    frame.refresh();

    return @backingInt(registered.node);
}

pub fn remainingAssignmentDepth(handle: *anyopaque) u64 {
    return Frame.borrow(handle).remaining;
}

pub fn rejectAssignmentDepth(handle: *anyopaque, node: u32) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frame.graph.reporter.fail(.unsupported, frame.node_spans[node], "type inference nesting exceeds 256 levels");
}

pub fn mergeAssignmentClass(handle: *anyopaque, row: u64, other: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const index: u32 = @intCast(row);

    try frame.graph.unify(@fromBackingInt(index), @fromBackingInt(other), frame.graph.nodes.items(.span)[index]);

    frame.refresh();
}

pub fn reserveAssignmentOptional(handle: *anyopaque, node: u32, payload: u32, layers: u64) zx.Error!u32 {
    const graph = Frame.borrow(handle).graph;
    const span = graph.nodes.items(.span)[node];
    const count = std.math.cast(usize, layers) orelse return error.OutOfMemory;

    return @backingInt(try graph.addContainers(@fromBackingInt(payload), .optional, count, span));
}
