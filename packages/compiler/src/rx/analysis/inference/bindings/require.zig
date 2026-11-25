const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const rules = @import("rules.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_require_binding_value");
const Input = std.meta.Child(entry.Input);
const Topology = std.meta.Child(@FieldType(Input, "topology"));
const Rows = std.meta.Child(@FieldType(Input, "rows"));

const Frame = struct {
    graph: *Graph,
    rows: Rows = undefined,
    values: []u32 = undefined,
    spans: []zx.Span = undefined,
    length: []usize = undefined,
};

pub fn run(graph: *Graph, value: Graph.Id, span: zx.Span) zx.Error!void {
    var frame: Frame = .{ .graph = graph };
    var parents = graph.parents();
    const source: []const zx.Span = &.{span};

    const input: Input = .{
        .topology = &.{ .graph = &rules.view(Topology, graph), .parents = @ptrCast(&parents) },
        .value = @backingInt(value),
        .frame = @ptrCast(&frame),
        .reporter = @ptrCast(graph.reporter),
        .span = &.{ .start = span.start, .end = span.end },
        .source = @ptrCast(&source),
        .rows = &frame.rows,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn reserveBindingUse(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame: *Frame = @ptrCast(@alignCast(handle));
    const pending = &frame.graph.pending;
    const uses = &pending.value_uses;

    try uses.ensureUnusedCapacity(pending.allocator, 1);

    var rows = uses.slice();

    rows.len += 1;
    frame.values = @ptrCast(rows.items(.value));
    frame.spans = rows.items(.span);
    frame.length = (&uses.len)[0..1];

    frame.rows = .{
        .values = @ptrCast(&frame.values),
        .spans = @ptrCast(&frame.spans),
        .length = @ptrCast(&frame.length),
        .first = uses.len,
    };
}
