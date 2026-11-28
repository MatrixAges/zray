const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../../inference/types.zig");
const Nodes = @import("../../../inference/nodes.zig");
const Ports = @import("../ports.zig");
const layout = @import("rx_execution_abi").layouts.@"zig:rx_project_host";

pub fn apply(graph: *Graph, rows: Ports.Slice, batches: []const *const layout.PortBatch) zx.Error!void {
    for (batches) |batch| {
        if (batch.offsets.len != 0) try inferred(graph, rows, @intCast(batch.first), batch.offsets);
        if (batch.declared) |port| try declared(graph, rows, port);
    }
}

fn inferred(graph: *Graph, destination: Ports.Slice, first: usize, offsets: []const u64) std.mem.Allocator.Error!void {
    var rows = destination;
    const count = offsets.len;
    const reservation = try Nodes.reserve(graph, std.math.mul(usize, count, 2) catch return error.OutOfMemory);
    const node_parents = reservation.rows.items(.parent);
    const kinds = reservation.rows.items(.kind);
    const arguments = reservation.rows.items(.argument);
    const members = reservation.rows.items(.members);
    const spans = reservation.rows.items(.span);
    const alloweds = reservation.rows.items(.allowed);
    const fallbacks = reservation.rows.items(.fallback);

    for (offsets, 0..) |offset, index| {
        const node: usize = reservation.first + index * 2;
        const pos: usize = @intCast(offset);
        const span: zx.Span = .{ .start = pos, .end = pos };
        const input_id: u32 = @intCast(node);
        const output_id: u32 = @intCast(node + 1);
        node_parents[node] = input_id;
        node_parents[node + 1] = output_id;
        kinds[node] = .Unknown;
        kinds[node + 1] = .Unknown;
        arguments[node] = 0;
        arguments[node + 1] = 0;
        members[node] = &.{};
        members[node + 1] = &.{};
        spans[node] = span;
        spans[node + 1] = span;
        alloweds[node] = null;
        alloweds[node + 1] = null;
        fallbacks[node] = null;
        fallbacks[node + 1] = null;

        rows.set(first + index, .{
            .input = @fromBackingInt(input_id),
            .output = @fromBackingInt(output_id),
            .input_fixed = false,
        });
    }

    graph.nodes.len = reservation.rows.len;
}

fn declared(graph: *Graph, destination: Ports.Slice, port: *const layout.DeclaredPort) zx.Error!void {
    var rows = destination;
    const pos: usize = @intCast(port.offset);
    const span: zx.Span = .{ .start = pos, .end = pos };

    rows.set(@intCast(port.row), .{
        .input = try graph.known(@fromBackingInt(port.input), span),
        .output = try graph.known(@fromBackingInt(port.output), span),
        .input_fixed = true,
    });
}
