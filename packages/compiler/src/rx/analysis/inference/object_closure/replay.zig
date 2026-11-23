const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const GraphColumns = @import("../fields/columns.zig");
const Fields = @import("../fields/replay.zig");
const Closure = @import("../object_closure.zig");
const Readiness = @import("host.zig");
const RowMemory = @import("../scoped_scratch.zig").Buffer(std.heap.page_size_min);
const Construction = @import("../construction/object.zig");
const Solve = @import("../../project/workflow/solve/abi.zig").Solve;
const Self = @This();
pub const View = std.meta.Child(@FieldType(Solve, "objects"));
pub const ConstructionRow = std.meta.Child(@FieldType(View, "construction"));
pub const SelectionRow = std.meta.Child(@FieldType(View, "selection"));
const Constructions = std.meta.Child(@FieldType(View, "constructions"));
const Selections = std.meta.Child(@FieldType(View, "selections"));
const Columns = std.meta.Child(@FieldType(Constructions, "columns"));

graph: *Graph = undefined,
scope: *zx.memory.ArenaScope = undefined,
memory: RowMemory = .{},
view: View = undefined,
columns: Columns = undefined,
constructions: Constructions = undefined,
selections: Selections = undefined,
readiness: Readiness.Session = undefined,
context: Readiness.Context = undefined,
fields: Fields.Frame = undefined,
constructed: Construction.Frame = undefined,
construction: ConstructionRow = undefined,
selection: SelectionRow = undefined,
source: std.meta.Child(@FieldType(SelectionRow, "source")) = undefined,
parents: []u32 = undefined,
revision: []u64 = undefined,
selection_spans: []const zx.Span = undefined,
pub fn bind(self: *Self, graph: *Graph, closure: *Closure, scope: *zx.memory.ArenaScope) void {
    self.graph = graph;
    self.scope = scope;
    self.revision = (&graph.revision)[0..1];
    self.readiness = .{ .graph = graph, .closure = closure };

    self.readiness.bind();

    const objects = graph.pending.constructions.slice();
    const selections = graph.pending.selections.slice();

    self.selection_spans = selections.items(.span);

    self.constructions = .{
        .columns = &self.columns,
        .parents = @ptrCast(&self.parents),
        .results = @ptrCast(objects.items(.result)),
        .parts = objects.items(.count),
    };

    self.selections = .{
        .parents = @ptrCast(&self.parents),
        .kinds = undefined,
        .sources = @ptrCast(selections.items(.source)),
        .constructions = objects.len,
        .revision = undefined,
        .owner = @ptrCast(graph),
        .spans = @ptrCast(&self.selection_spans),
    };

    self.view = .{
        .frame = @ptrCast(self),
        .constructions = &self.constructions,
        .construction = &self.construction,
        .selections = &self.selections,
        .selection = &self.selection,
        .readiness = &self.context,
        .revision = @ptrCast(&self.revision),
    };

    self.refresh();
}

fn refresh(self: *Self) void {
    self.columns = GraphColumns.borrow(Columns, self.graph);
    self.parents = self.graph.parents();
    self.context = self.readiness.context();
    self.selections.kinds = self.context.kinds;
    self.selections.revision = self.context.revision;
}

pub fn from(handle: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn finishObjectRow(handle: *const anyopaque) void {
    const frame = from(handle);

    frame.memory.close(frame.scope);
    frame.refresh();
}
