const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Object = @import("../construction.zig").Object;
const GraphColumns = @import("../fields/columns.zig");
const Closure = @import("../object_closure.zig");
const rule = @import("generated_rx_replay_object_construction");
const Input = std.meta.Child(rule.Input);
const Views = std.meta.Child(@FieldType(Input, "views"));
const Columns = std.meta.Child(@FieldType(Views, "columns"));
const Objects = std.MultiArrayList(Object).Slice;

const Frame = struct {
    graph: *Graph,
    closure: *Closure,
    objects: Objects,
    final: bool,
    columns: Columns = undefined,
    parents: []u32 = undefined,
    fn bind(self: *Frame) void {
        self.columns = GraphColumns.borrow(Columns, self.graph);
        self.parents = self.graph.parents();
    }
};

pub fn run(graph: *Graph, closure: *Closure, objects: Objects, final: bool) zx.Error!void {
    if (objects.len == 0) return;

    var frame: Frame = .{ .graph = graph, .closure = closure, .objects = objects, .final = final };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .views = &.{
            .columns = &frame.columns,
            .parents = @ptrCast(&frame.parents),
            .results = @ptrCast(objects.items(.result)),
            .parts = objects.items(.count),
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../../project/workflow/errors.zig");

    rule.executeIn(empty.allocator(), &input) catch |err| return workflow.errorSet(err);
}

pub fn replayObjectConstruction(handle: *const anyopaque, row: u64, root: u32) zx.Error!void {
    const frame: *Frame = @ptrCast(@alignCast(@constCast(handle)));
    const object = frame.objects.get(@intCast(row));

    try @import("project.zig").propagate(frame.graph, frame.closure, object, @fromBackingInt(root), frame.final);

    frame.bind();
}
