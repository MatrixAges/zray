const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Selection = @import("../selection.zig");
const Kind = @import("../nodes.zig").Kind;
const Closure = @import("../object_closure.zig");
const Readiness = @import("../object_closure/host.zig");
const rule = @import("generated_rx_replay_object_selection");
const Input = std.meta.Child(rule.Input);
const Views = std.meta.Child(@FieldType(Input, "views"));
const Selections = std.MultiArrayList(Selection.Selection).Slice;

const Frame = struct {
    graph: *Graph,
    readiness: Readiness.Session,
    pending: Selections,
    views: Views = undefined,
    parents: []u32 = undefined,
    fn bind(self: *Frame) void {
        const kinds: []const Kind = self.graph.nodes.items(.kind);

        self.views.kinds = zx.columns.slice(@FieldType(Views, "kinds"), kinds);
        self.parents = self.graph.parents();
        self.views.revision = self.graph.object_revision;

        self.readiness.bind();
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, closure: *Closure, pending: Selections, final: bool) zx.Error!void {
    if (pending.len == 0) return;

    var frame: Frame = .{
        .graph = graph,
        .readiness = .{ .graph = graph, .closure = closure },
        .pending = pending,
    };

    frame.views = .{
        .parents = @ptrCast(&frame.parents),
        .kinds = undefined,
        .sources = @ptrCast(pending.items(.source)),
        .constructions = graph.pending.constructions.len,
        .revision = undefined,
        .final = final,
    };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .readiness = &frame.readiness.context(),
        .views = &frame.views,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../../project/workflow/errors.zig");

    rule.executeIn(empty.allocator(), &input) catch |err| return workflow.errorSet(err);
}

pub fn replayObjectSelection(handle: *const anyopaque, row: u64, root: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const value = frame.pending.get(@intCast(row));

    try @import("project.zig").apply(frame.graph, value, @fromBackingInt(root), frame.views.final);

    frame.bind();
}

pub fn rejectObjectSelection(handle: *const anyopaque, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);
    const span = frame.pending.items(.span)[@intCast(row)];

    return frame.graph.reporter.fail(.type_mismatch, span, Selection.incomplete_source);
}
