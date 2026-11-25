const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Known = @import("../known.zig");
const Topology = @import("../optional/topology.zig").borrowType;
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_read_non_null");
const Input = std.meta.Child(entry.Input);
const Node = std.meta.Child(@FieldType(Input, "node"));
const Rows = std.meta.Child(@FieldType(Input, "rows"));

const Frame = struct {
    graph: *Graph,
    span: zx.Span,
    node: Node = undefined,
    append: Nodes.Append(Node) = undefined,
    rows: Rows = undefined,
    sources: []u32 = undefined,
    values: []u32 = undefined,
    spans: []zx.Span = undefined,
    length: []usize = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(graph: *Graph, source: Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    var frame: Frame = .{ .graph = graph, .span = span };
    var topology: Topology(Input) = undefined;

    topology.bind(graph);

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .graph = &topology.graph,
        .known = &topology.known,
        .parents = @ptrCast(&topology.parents),
        .value = @backingInt(source),
        .node = &frame.node,
        .rows = &frame.rows,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const value = entry.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);

    return @fromBackingInt(value);
}

pub fn registerGuardedPayload(handle: *anyopaque, value: u32, remaining: u64) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const result = try Known.registerPayload(frame.graph, value, remaining, frame.span);

    return @backingInt(result.node);
}

pub fn reserveNonNullNode(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const reservation = try Nodes.reserve(frame.graph, 1);

    frame.append.bind(&frame.node, frame.graph, reservation, .unknown, frame.span);
}

pub fn reserveNonNullProjection(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;
    const projections = &pending.nonnull;

    try projections.ensureUnusedCapacity(pending.allocator, 1);

    var rows = projections.slice();

    rows.len += 1;
    frame.sources = @ptrCast(rows.items(.source));
    frame.values = @ptrCast(rows.items(.value));
    frame.spans = rows.items(.span);
    frame.length = (&projections.len)[0..1];

    frame.rows = .{
        .sources = @ptrCast(&frame.sources),
        .values = @ptrCast(&frame.values),
        .spans = @ptrCast(&frame.spans),
        .length = @ptrCast(&frame.length),
        .position = projections.len,
    };
}
