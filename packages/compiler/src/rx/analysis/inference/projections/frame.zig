const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Target = @import("../sequences/target.zig");
const Solve = @import("../../project/workflow/solve/abi.zig").Solve;
const Sequences = std.meta.Child(@FieldType(Solve, "sequences"));
const Lengths = std.meta.Child(@FieldType(Solve, "lengths"));
const Indexes = std.meta.Child(@FieldType(Solve, "indexes"));
const Known = std.meta.Child(@FieldType(Lengths, "known"));
const Self = @This();

sequences: Sequences,
lengths: Lengths,
indexes: Indexes,
parents: []u32,
known: Known,
length_types: std.meta.Child(@FieldType(Lengths, "types")),
sequence_view: std.meta.Child(@FieldType(Indexes, "graph")),
sequence_spans: []const zx.Span,
length_spans: []const zx.Span,
index_spans: []const zx.Span,
position_spans: []const zx.Span,
resolution: []bool,
pub fn bindSequences(self: *Self, graph: *Graph, handle: *const anyopaque) void {
    const rows = graph.pending.sequences.slice();

    self.parents = graph.parents();
    self.sequence_view = Target.borrow(@TypeOf(self.sequence_view), graph);
    self.sequence_spans = rows.items(.span);

    self.sequences = .{
        .frame = @ptrCast(handle),
        .owner = @ptrCast(graph),
        .spans = @ptrCast(&self.sequence_spans),
        .graph = &self.sequence_view,
        .parents = @ptrCast(&self.parents),
        .values = @ptrCast(rows.items(.value)),
        .elements = @ptrCast(rows.items(.elements)),
    };
}

pub fn bindLengths(self: *Self, graph: *Graph, handle: *const anyopaque) void {
    const rows = graph.pending.lengths.slice();
    const nodes = graph.nodes.slice();
    const types = &graph.types.items;
    const kinds: []const Nodes.Kind = nodes.items(.kind);

    self.parents = graph.parents();
    self.known = graph.pending.known_types.borrow(Known);
    self.length_spans = rows.items(.span);

    self.length_types = .{
        .kinds = types.kinds.items,
        .first = types.first.items,
        .second = types.second.items,
        .field_names = types.field_names.items,
        .field_types = types.field_types.items,
    };

    self.lengths = .{
        .frame = @ptrCast(handle),
        .owner = @ptrCast(graph),
        .kinds = zx.columns.slice(@FieldType(Lengths, "kinds"), kinds),
        .arguments = nodes.items(.argument),
        .allowed = nodes.items(.allowed),
        .types = &self.length_types,
        .parents = @ptrCast(&self.parents),
        .known = &self.known,
        .targets = @ptrCast(rows.items(.target)),
        .values = @ptrCast(rows.items(.value)),
        .spans = @ptrCast(&self.length_spans),
    };
}

pub fn bindIndexes(self: *Self, graph: *Graph, handle: *const anyopaque) void {
    const rows = graph.pending.indexes.slice();

    self.parents = graph.parents();
    self.known = graph.pending.known_types.borrow(Known);
    self.sequence_view = Target.borrow(@TypeOf(self.sequence_view), graph);
    self.index_spans = rows.items(.span);
    self.position_spans = rows.items(.index_span);
    self.resolution = rows.items(.resolved);

    self.indexes = .{
        .frame = @ptrCast(handle),
        .owner = @ptrCast(graph),
        .graph = &self.sequence_view,
        .parents = @ptrCast(&self.parents),
        .known = &self.known,
        .targets = @ptrCast(rows.items(.target)),
        .values = @ptrCast(rows.items(.value)),
        .spans = @ptrCast(&self.index_spans),
        .index_spans = @ptrCast(&self.position_spans),
        .resolved = self.resolution,
        .resolution = @ptrCast(&self.resolution),
        .positions = rows.items(.position),
    };
}
