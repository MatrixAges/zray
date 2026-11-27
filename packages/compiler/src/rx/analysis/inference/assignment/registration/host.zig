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
const Known = std.meta.Child(@typeInfo(@FieldType(Batch, "known")).optional.child);

const Frame = struct {
    graph: *Graph,
    source_spans: []const zx.Span,
    parents: []u32 = undefined,
    known: Known = undefined,
    storage: Storage = undefined,
    fn open(self: *Frame) void {
        self.parents = self.graph.parents();

        self.bindRows();
    }
    fn bindRows(self: *Frame) void {
        const pending = &self.graph.pending.assignments;
        var reserved = pending.slice();
        reserved.len = reserved.capacity;
        const keys = reserved.items(.key);

        self.storage = .{
            .keys = keys,
            .buckets = self.graph.pending.assignment_keys.index,
            .capacity = keys.len,
        };
    }

    fn bindKnown(self: *Frame) void {
        self.parents = self.graph.parents();
        self.known = self.graph.pending.known_types.borrow(Known);
    }

    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn expect(graph: *Graph, value: Graph.Id, expected: Graph.Id, span: zx.Span) zx.Error!void {
    const spans = [_]zx.Span{span};
    var frame: Frame = .{ .graph = graph, .source_spans = &spans };

    frame.open();

    const input: Single = .{
        .frame = @ptrCast(&frame),
        .storage = &frame.storage,
        .position = graph.pending.assignments.len,
        .endpoints = &.{ .left = @backingInt(value), .right = @backingInt(expected), .parents = @ptrCast(&frame.parents) },
    };

    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var buf: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buf, arena.allocator());

    single.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
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

    frame.open();

    if (targets == .declared) frame.bindKnown();

    const input: Batch = .{
        .frame = @ptrCast(&frame),
        .storage = &frame.storage,
        .position = graph.pending.assignments.len,
        .parents = @ptrCast(&frame.parents),
        .values = @ptrCast(values),
        .targets = members,
        .repeated = if (targets == .repeated) @backingInt(targets.repeated) else null,
        .known = if (targets == .declared) &frame.known else null,
    };

    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var buf: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buf, arena.allocator());

    series.executeIn(scratch.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn commitAssignment(handle: *anyopaque, left: u32, right: u32, key: u64, slot: u64, span_index: u64) void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;
    const row: u32 = @intCast(pending.assignments.len);

    std.debug.assert(pending.assignments.len < pending.assignments.capacity);

    pending.assignments.appendAssumeCapacity(.{
        .value = @fromBackingInt(left),
        .expected = @fromBackingInt(right),
        .span = frame.source_spans[@intCast(span_index)],
        .key = key,
    });

    pending.assignment_keys.index[@intCast(slot)] = row;

    frame.graph.revision += 1;

    frame.bindRows();
}

pub fn replaceAssignmentIndex(handle: *anyopaque, buckets: []const u32) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;
    const fresh = try pending.allocator.dupe(u32, buckets);

    pending.allocator.free(pending.assignment_keys.index);

    pending.assignment_keys.index = fresh;
    frame.storage.buckets = fresh;
}

pub fn growAssignmentRows(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;

    try pending.assignments.ensureUnusedCapacity(pending.allocator, 1);

    frame.bindRows();
}

pub fn registerAssignmentTarget(handle: *anyopaque, type_id: u32, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);

    _ = try frame.graph.known(@fromBackingInt(type_id), frame.source_spans[@intCast(row)]);

    frame.bindKnown();
}
