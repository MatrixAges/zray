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
known: Known,
length_types: std.meta.Child(@FieldType(Lengths, "types")),
sequence_view: std.meta.Child(@FieldType(Indexes, "graph")),
pub fn bindSequences(self: *Self, graph: *Graph) void {
    const rows = graph.pending.sequences.slice();

    self.sequence_view = Target.borrow(@TypeOf(self.sequence_view), graph);

    self.sequences = .{
        .spans = .Sequence,
        .graph = &self.sequence_view,
        .parents = graph.parents(),
        .values = @ptrCast(rows.items(.value)),
        .elements = @ptrCast(rows.items(.elements)),
    };
}

pub fn bindLengths(self: *Self, graph: *Graph) void {
    const rows = graph.pending.lengths.slice();
    const nodes = graph.nodes.slice();
    const types = &graph.types.items;
    const kinds: []const Nodes.Kind = nodes.items(.kind);

    self.known = graph.pending.known_types.borrow(Known);

    self.length_types = .{
        .kinds = types.kinds.items,
        .first = types.first.items,
        .second = types.second.items,
        .field_names = types.field_names.items,
        .field_types = types.field_types.items,
    };

    self.lengths = .{
        .kinds = zx.columns.slice(@FieldType(Lengths, "kinds"), kinds),
        .arguments = nodes.items(.argument),
        .allowed = nodes.items(.allowed),
        .types = &self.length_types,
        .parents = graph.parents(),
        .known = &self.known,
        .targets = @ptrCast(rows.items(.target)),
        .values = @ptrCast(rows.items(.value)),
        .spans = .Length,
    };
}

pub fn bindIndexes(self: *Self, graph: *Graph) void {
    const rows = graph.pending.indexes.slice();

    self.known = graph.pending.known_types.borrow(Known);
    self.sequence_view = Target.borrow(@TypeOf(self.sequence_view), graph);

    self.indexes = .{
        .graph = &self.sequence_view,
        .parents = graph.parents(),
        .known = &self.known,
        .targets = @ptrCast(rows.items(.target)),
        .values = @ptrCast(rows.items(.value)),
        .spans = .Index,
        .index_spans = .IndexPosition,
        .resolved = rows.items(.resolved),
        .positions = rows.items(.position),
    };
}
