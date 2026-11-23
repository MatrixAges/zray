const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Kind = @import("../nodes.zig").Kind;
const NonNull = @import("../non_null.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_replay_non_null");
const Input = std.meta.Child(entry.Input);
const View = std.meta.Child(@FieldType(Input, "graph"));
const Types = std.meta.Child(@FieldType(View, "types"));
const Known = std.meta.Child(@FieldType(Input, "known"));
const Rows = std.MultiArrayList(NonNull.Projection).Slice;

const Frame = struct {
    graph: *Graph,
    projections: Rows,
    view: View = undefined,
    types: Types = undefined,
    known: Known = undefined,
    parents: []u32 = undefined,
    fn bind(self: *Frame) void {
        const graph = self.graph;
        const rows = graph.nodes.slice();
        const kinds: []const Kind = rows.items(.kind);
        self.types = .{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items };
        self.view = .{ .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds), .arguments = rows.items(.argument), .types = &self.types };
        self.known = graph.pending.known_types.borrow(Known);
        self.parents = graph.parents();
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, infer_source: bool) zx.Error!void {
    const projections = graph.pending.nonnull.slice();

    if (projections.len == 0) return;

    var frame: Frame = .{ .graph = graph, .projections = projections };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .graph = &frame.view,
        .parents = @ptrCast(&frame.parents),
        .sources = @ptrCast(projections.items(.source)),
        .values = @ptrCast(projections.items(.value)),
        .known = &frame.known,
        .infer_source = infer_source,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn unifyNonNullReplay(handle: *const anyopaque, row: u64, value: u32, register: bool) zx.Error!void {
    const frame = Frame.borrow(handle);
    const projection = frame.projections.get(@intCast(row));
    const node: Graph.Id = if (register) try frame.graph.known(@fromBackingInt(value), projection.span) else @fromBackingInt(value);

    try frame.graph.unify(projection.value, node, projection.span);

    frame.bind();
}

pub fn inferNonNullReplay(handle: *const anyopaque, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);

    try NonNull.infer(frame.graph, frame.projections.get(@intCast(row)));

    frame.bind();
}
