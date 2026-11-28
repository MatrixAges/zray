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
selection_spans: []const zx.Span = undefined,
pub fn bind(self: *Self, graph: *Graph, closure: *Closure, scope: *zx.memory.ArenaScope) void {
    self.graph = graph;
    self.scope = scope;
    self.readiness = .{ .graph = graph, .closure = closure };

    self.readiness.bind();

    const objects = graph.pending.constructions.slice();
    const selections = graph.pending.selections.slice();

    self.selection_spans = selections.items(.span);

    self.constructions = .{
        .columns = &self.columns,
        .parents = undefined,
        .results = @ptrCast(objects.items(.result)),
        .parts = objects.items(.count),
    };

    self.selections = .{
        .parents = undefined,
        .kinds = undefined,
        .sources = @ptrCast(selections.items(.source)),
        .constructions = objects.len,
        .revision = undefined,
        .owner = @ptrCast(graph),
        .spans = @ptrCast(&self.selection_spans),
    };

    self.view = .{
        .constructions = &self.constructions,
        .construction = &self.construction,
        .selections = &self.selections,
        .selection = &self.selection,
        .readiness = &self.context,
    };

    self.refresh();
}

fn refresh(self: *Self) void {
    self.columns = GraphColumns.borrow(Columns, self.graph);
    self.constructions.parents = self.graph.parents();
    self.selections.parents = self.constructions.parents;
    self.context = self.readiness.context();
    self.selections.kinds = self.context.kinds;
    self.selections.revision = self.context.revision;
}

pub fn commit(self: *Self, effect: anytype, reply: anytype) zx.Error!void {
    switch (effect.object_step) {
        .UpdateReadiness => reply.ready = try Readiness.updateReadiness(&self.readiness, effect.rebuild.?, effect.position.?, effect.spread.?, effect.shared.?),
        .OpenConstruction => Construction.openRow(self, effect.row.?, effect.root.?, effect.final.?),
        .OpenSelection => @import("../selection/host.zig").openRow(self, effect.row.?, effect.root.?),
        .FinishRow => {
            self.memory.close(self.scope);
            self.refresh();
        },
        .ReserveSpreads, .BindSpread, .CommitSpread, .RegisterSource, .DescribeTarget, .InferField, .RejectConstruction =>
            try Construction.apply(&self.constructed, effect, reply),
        else => try Fields.apply(&self.fields, effect, reply),
    }
}
