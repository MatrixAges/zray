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
    known: Known = undefined,
    storage: Storage = undefined,
    fn bindRows(self: *Frame) void {
        const pending = &self.graph.pending.assignments;
        var reserved = pending.slice();
        reserved.len = reserved.capacity;
        const keys = reserved.items(.key);

        self.storage = .{
            .keys = keys,
            .parents = self.graph.parents(),
            .buckets = self.graph.pending.assignment_keys.index,
            .capacity = keys.len,
        };
    }
    fn bindKnown(self: *Frame) void {
        self.storage.parents = self.graph.parents();
        self.known = self.graph.pending.known_types.borrow(Known);
    }
};

pub fn expect(graph: *Graph, value: Graph.Id, expected: Graph.Id, span: zx.Span) zx.Error!void {
    const spans = [_]zx.Span{span};
    var frame: Frame = .{ .graph = graph, .source_spans = &spans };

    frame.bindRows();

    const input: Single = .{
        .storage = &frame.storage,
        .position = graph.pending.assignments.len,
        .endpoints = &.{ .left = @backingInt(value), .right = @backingInt(expected), .parents = frame.storage.parents },
    };

    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var buf: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buf, arena.allocator());

    try execute(single, &frame, scratch.allocator(), &input);
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

    frame.bindRows();

    if (targets == .declared) frame.bindKnown();

    const input: Batch = .{
        .storage = &frame.storage,
        .position = graph.pending.assignments.len,
        .values = @ptrCast(values),
        .targets = members,
        .repeated = if (targets == .repeated) @backingInt(targets.repeated) else null,
        .known = if (targets == .declared) &frame.known else null,
    };

    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var buf: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buf, arena.allocator());

    try execute(series, &frame, scratch.allocator(), &input);
}

fn execute(comptime entry: type, frame: *Frame, allocator: std.mem.Allocator, input: entry.Input) zx.Error!void {
    const Store = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));

    const Host = struct {
        frame: *Frame,
        store_0: *Store,
        pub fn commit(host: *@This(), pending: entry.zx_pending) zx.Error!void {
            const effect = pending.store_0 orelse return;
            const current = host.frame;

            switch (effect.registration_step) {
                .Overflow => return error.OutOfMemory,
                .Append => commitAssignment(current, effect.row.?),
                .ReplaceIndex => try replaceAssignmentIndex(current, effect.buckets.?),
                .Grow => try growAssignmentRows(current),
                .RegisterTarget => try registerAssignmentTarget(current, effect.type_id.?, effect.span_index.?),
            }
        }
    };

    const initial = @import("../../../project/workflow/execute.zig").snapshot(std.meta.Child(Store), .{ .registration_step = .Append });
    var store: Store = &initial;
    var host: Host = .{ .frame = frame, .store_0 = &store };

    entry.executeIn(allocator, input, &host) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return errors.errorSet(err),
    };
}

fn commitAssignment(frame: *Frame, entry: anytype) void {
    const pending = &frame.graph.pending;
    const row: u32 = @intCast(pending.assignments.len);

    std.debug.assert(pending.assignments.len < pending.assignments.capacity);

    pending.assignments.appendAssumeCapacity(.{
        .value = @fromBackingInt(entry.left),
        .expected = @fromBackingInt(entry.right),
        .span = frame.source_spans[@intCast(entry.span_index)],
        .key = entry.key,
    });

    pending.assignment_keys.index[@intCast(entry.slot)] = row;

    frame.graph.revision += 1;

    frame.bindRows();
}

fn replaceAssignmentIndex(frame: *Frame, buckets: []const u32) std.mem.Allocator.Error!void {
    const pending = &frame.graph.pending;
    const fresh = try pending.allocator.dupe(u32, buckets);

    pending.allocator.free(pending.assignment_keys.index);

    pending.assignment_keys.index = fresh;
    frame.storage.buckets = fresh;
}

fn growAssignmentRows(frame: *Frame) std.mem.Allocator.Error!void {
    const pending = &frame.graph.pending;

    try pending.assignments.ensureUnusedCapacity(pending.allocator, 1);

    frame.bindRows();
}

fn registerAssignmentTarget(frame: *Frame, type_id: u32, row: u64) zx.Error!void {
    _ = try frame.graph.known(@fromBackingInt(type_id), frame.source_spans[@intCast(row)]);

    frame.bindKnown();
}
