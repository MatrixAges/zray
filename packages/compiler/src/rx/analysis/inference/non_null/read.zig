const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Known = @import("../known.zig");
const Topology = @import("../optional/topology.zig").borrowType;
const entry = @import("generated_rx_read_non_null");
const Input = std.meta.Child(entry.Input);

pub fn run(graph: *Graph, source: Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    var topology: Topology(Input) = undefined;

    topology.bind(graph);

    const input: Input = .{
        .graph = &topology.graph,
        .known = &topology.known,
        .parents = @ptrCast(&topology.parents),
        .value = @backingInt(source),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const guard = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

    if (guard.action == .Register) {
        return (try Known.registerPayload(graph, guard.value.?, guard.remaining, span)).node;
    }

    if (guard.value) |value| return @fromBackingInt(value);

    const value = try graph.add(.unknown, span);

    errdefer graph.nodes.len -= 1;

    try graph.pending.nonnull.append(graph.pending.allocator, .{ .source = source, .value = value, .span = span });

    return value;
}
