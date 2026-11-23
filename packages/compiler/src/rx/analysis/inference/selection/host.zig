const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Fields = @import("../fields/replay.zig");
const View = @import("../fields/view.zig");
const errors = @import("../../project/workflow/errors.zig");
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

    rule.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn replayObjectSelection(handle: *const anyopaque, row: u64, root: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const value = frame.pending.get(@intCast(row));
    const apply = @import("generated_rx_apply_object_selection");
    const Apply = std.meta.Child(apply.Input);
    const source = View.read(frame.graph, @fromBackingInt(root));
    var arena = std.heap.ArenaAllocator.init(frame.graph.scratch);

    defer arena.deinit();

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    var fields: Fields.Frame = .{ .graph = frame.graph, .result = value.result, .span = value.span };

    const input: Apply = .{
        .frame = @ptrCast(&fields),
        .field_view = &fields.view,
        .source = &.{ .names = source.names, .values = source.values },
        .mode = zx.columns.view(@FieldType(Apply, "mode"), source.mode),
        .keys = value.keys,
        .omit = value.omit,
        .final = frame.views.final,
    };

    apply.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return errors.errorSet(err),
    };

    frame.bind();
}

pub fn rejectObjectSelection(handle: *const anyopaque, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);
    const span = frame.pending.items(.span)[@intCast(row)];

    return frame.graph.reporter.fail(.type_mismatch, span, Selection.incomplete_source);
}
