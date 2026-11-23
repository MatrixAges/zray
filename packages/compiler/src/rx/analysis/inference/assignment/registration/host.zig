const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const Registration = @import("../registration.zig");
const errors = @import("../../../project/workflow/errors.zig");
const single = @import("generated_rx_register_assignment");
const series = @import("generated_rx_register_assignment_series");
const Single = std.meta.Child(single.Input);
const Batch = std.meta.Child(series.Input);
const Storage = std.meta.Child(@FieldType(Single, "storage"));
const Destination = std.meta.Child(@FieldType(Storage, "rows"));
const Visibility = std.meta.Child(@FieldType(Storage, "visibility"));
const Known = std.meta.Child(@typeInfo(@FieldType(Batch, "known")).optional.child);

const Frame = struct {
    graph: *Graph,
    source_spans: []const zx.Span,
    left: []u32 = undefined,
    right: []u32 = undefined,
    keys: []u64 = undefined,
    spans: []u8 = undefined,
    parents: []u32 = undefined,
    known: Known = undefined,
    rows: Destination = undefined,
    storage: Storage = undefined,
    new_buckets: []u32 = &.{},
    length: []usize = undefined,
    revision: []u64 = undefined,
    visibility: Visibility = undefined,
    fn open(self: *Frame) void {
        const graph = self.graph;
        const pending = &graph.pending;
        self.parents = self.graph.parents();
        self.length = (&pending.assignments.len)[0..1];
        self.revision = (&graph.revision)[0..1];
        self.visibility = .{ .length = @ptrCast(&self.length), .revision = @ptrCast(&self.revision) };

        self.rows = .{
            .left = @ptrCast(&self.left),
            .right = @ptrCast(&self.right),
            .keys = @ptrCast(&self.keys),
            .buckets = @ptrCast(&pending.assignment_keys.index),
            .capacity = undefined,
        };

        self.storage = .{
            .keys = undefined,
            .rows = &self.rows,
            .spans = @ptrCast(&self.spans),
            .allocator = @ptrCast(&pending.allocator),
            .replacement = @ptrCast(&self.new_buckets),
            .visibility = &self.visibility,
        };

        self.bindRows();
    }
    fn bindRows(self: *Frame) void {
        const pending = &self.graph.pending.assignments;
        var reserved = pending.slice();
        reserved.len = reserved.capacity;
        self.left = @ptrCast(reserved.items(.value));
        self.right = @ptrCast(reserved.items(.expected));
        self.keys = reserved.items(.key);
        self.spans = std.mem.sliceAsBytes(reserved.items(.span));
        self.rows.capacity = self.keys.len;
        self.storage.keys = self.keys;
    }

    fn bindKnown(self: *Frame) void {
        self.parents = self.graph.parents();
        self.known = self.graph.pending.known_types.borrow(Known);
    }

    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn expect(graph: *Graph, value: Graph.Id, expected: Graph.Id, span: zx.Span) zx.Error!void {
    var frame: Frame = .{ .graph = graph, .source_spans = &.{} };

    errdefer zx.memory.releaseU32Buffer(@ptrCast(&graph.pending.allocator), @ptrCast(&frame.new_buckets));
    frame.open();

    const input: Single = .{
        .frame = @ptrCast(&frame),
        .storage = &frame.storage,
        .position = graph.pending.assignments.len,
        .endpoints = &.{ .left = @backingInt(value), .right = @backingInt(expected), .parents = @ptrCast(&frame.parents) },
        .source = &.{ .source = std.mem.asBytes(&span), .width = @sizeOf(zx.Span) },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    single.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return errors.errorSet(err),
    };
}

pub fn expectMany(graph: *Graph, values: []const Graph.Id, spans: []const zx.Span, targets: Registration.Targets) zx.Error!void {
    const members: []const u32 = switch (targets) {
        .inferred, .declared => |ids| ids,
        .repeated => &.{},
    };

    std.debug.assert(values.len == spans.len);
    std.debug.assert(targets == .repeated or values.len == members.len);

    if (values.len == 0) return;

    var frame: Frame = .{ .graph = graph, .source_spans = spans };

    errdefer zx.memory.releaseU32Buffer(@ptrCast(&graph.pending.allocator), @ptrCast(&frame.new_buckets));
    frame.open();

    if (targets == .declared) frame.bindKnown();

    const input: Batch = .{
        .frame = @ptrCast(&frame),
        .storage = &frame.storage,
        .position = graph.pending.assignments.len,
        .source = &.{ .source = std.mem.sliceAsBytes(spans), .width = @sizeOf(zx.Span) },
        .parents = @ptrCast(&frame.parents),
        .values = @ptrCast(values),
        .targets = members,
        .repeated = if (targets == .repeated) @backingInt(targets.repeated) else null,
        .known = if (targets == .declared) &frame.known else null,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    series.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn growAssignmentRows(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;

    try pending.assignments.ensureUnusedCapacity(pending.allocator, 1);

    frame.bindRows();
}

pub fn registerAssignmentTarget(handle: *const anyopaque, type_id: u32, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);

    _ = try frame.graph.known(@fromBackingInt(type_id), frame.source_spans[@intCast(row)]);

    frame.bindKnown();
}
