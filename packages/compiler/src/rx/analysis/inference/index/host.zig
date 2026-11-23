const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Projection = @import("../index.zig").Projection;
const Target = @import("../sequences/target.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_replay_indexes");
const Input = std.meta.Child(entry.Input);
const immediate_rule = @import("generated_rx_resolve_index");
const ImmediateInput = std.meta.Child(immediate_rule.Input);
const ApplicationRef = @FieldType(ImmediateInput, "projection");
const View = std.meta.Child(@FieldType(Input, "graph"));
const Known = std.meta.Child(@FieldType(Input, "known"));
const Rows = std.MultiArrayList(Projection).Slice;

const Application = struct {
    graph: *Graph,
    projection: Projection,
    fn borrow(handle: *const anyopaque) *const Application {
        return @ptrCast(@alignCast(handle));
    }
};

const Frame = struct {
    application: Application,
    rows: Rows,
    view: View = undefined,
    known: Known = undefined,
    parents: []u32 = undefined,
    fn bind(self: *Frame) void {
        self.view = Target.borrow(entry, self.application.graph);
        self.known = self.application.graph.pending.known_types.borrow(Known);
        self.parents = self.application.graph.parents();
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn immediate(graph: *Graph, projection: Projection) zx.Error!bool {
    const application: Application = .{ .graph = graph, .projection = projection };
    const root = graph.root(projection.target);
    const view = Target.borrow(immediate_rule, graph);

    const input: ImmediateInput = .{
        .projection = @ptrCast(&application),
        .graph = &view,
        .root = @backingInt(root),
        .position = projection.position,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return immediate_rule.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn run(graph: *Graph, rows: Rows) zx.Error!void {
    if (rows.len == 0) return;

    const resolved = rows.items(.resolved);
    const resolution = std.mem.sliceAsBytes(resolved);
    var frame: Frame = .{ .application = .{ .graph = graph, .projection = undefined }, .rows = rows };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .graph = &frame.view,
        .parents = @ptrCast(&frame.parents),
        .targets = @ptrCast(rows.items(.target)),
        .values = @ptrCast(rows.items(.value)),
        .resolved = resolved,
        .resolution = @ptrCast(&resolution),
        .positions = rows.items(.position),
        .known = &frame.known,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn readReplayIndex(handle: *const anyopaque, row: u64) ApplicationRef {
    const frame = Frame.borrow(handle);

    frame.application.projection = frame.rows.get(@intCast(row));

    return @ptrCast(&frame.application);
}

pub fn commitReplayIndex(handle: *const anyopaque, row: u64, resolved: bool) void {
    const frame = Frame.borrow(handle);

    frame.rows.items(.resolved)[@intCast(row)] = resolved;
    frame.bind();
}

pub fn unifyIndexProjection(handle: *const anyopaque, value: u32, declared: bool) zx.Error!void {
    const frame = Application.borrow(handle);
    const projection = frame.projection;
    const child = try Target.child(frame.graph, value, declared, projection.span);

    try frame.graph.unify(child, projection.value, projection.span);
}

pub fn rejectIndexProjection(handle: *const anyopaque, message: ?[]const u8, at_index: bool) zx.Error!void {
    const frame = Application.borrow(handle);
    const projection = frame.projection;

    return frame.graph.reporter.fail(.type_mismatch, if (at_index) projection.index_span else projection.span, message.?);
}
