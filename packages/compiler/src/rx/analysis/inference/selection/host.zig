const zx = @import("zx");
const Replay = @import("../object_closure/replay.zig");
const View = @import("../fields/view.zig");

pub fn openSelectionRow(handle: *anyopaque, row: u64, root: u32) void {
    const frame = Replay.from(handle);
    const graph = frame.graph;
    const selection = graph.pending.selections.get(@intCast(row));
    const source = View.read(graph, @fromBackingInt(root));

    _ = frame.memory.open(frame.scope, graph.scratch);
    frame.fields = .{ .graph = graph, .result = selection.result, .span = selection.span };
    frame.source = .{ .names = source.names, .values = source.values };

    frame.selection = .{
        .frame = @ptrCast(&frame.fields),
        .field_view = &frame.fields.view,
        .source = &frame.source,
        .mode = zx.columns.view(@FieldType(Replay.SelectionRow, "mode"), source.mode),
        .keys = selection.keys,
        .omit = selection.omit,
    };
}
