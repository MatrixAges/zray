const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
pub const Kind = enum { list, optional };

pub fn append(graph: *Graph, payload: ?Graph.Id, kind: Kind, count: usize, span: zx.Span) zx.Error!Graph.Id {
    if (count == 0) return payload.?;

    if (comptime !@import("rx_options").generated_graph) {
        var child = payload orelse try graph.add(.unknown, span);

        for (0..count) |_| {
            child = try graph.add(switch (kind) {
                .list => .{ .list = child },
                .optional => .{ .optional = child },
            }, span);
        }

        return child;
    }

    const rows_count = std.math.add(usize, count, @intFromBool(payload == null)) catch return error.OutOfMemory;
    const reservation = try Nodes.reserve(graph, rows_count);
    const writer = @import("generated_rx_inference_containers");
    const Input = std.meta.Child(writer.Input);
    const rows = Nodes.writable(reservation.rows);
    const parents = reservation.rows.items(.parent);
    const publication = Nodes.Publication.init(graph, reservation.rows);

    const container: Nodes.Kind = switch (kind) {
        .list => .List,
        .optional => .Optional,
    };

    const input: Input = .{
        .parents = @ptrCast(&parents),
        .columns = &rows.borrow(std.meta.Child(@FieldType(Input, "columns"))),
        .first = reservation.first,
        .end = reservation.rows.len,
        .payload = if (payload) |id| @backingInt(id) else null,
        .container = @backingInt(container),
        .unknown = @backingInt(Nodes.Kind.Unknown),
        .storage = &publication.storage(std.meta.Child(@FieldType(Input, "storage"))),
        .span = &publication.span(std.meta.Child(@FieldType(Input, "span")), span),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    writer.executeIn(empty.allocator(), &input) catch unreachable;

    return @fromBackingInt(@intCast(reservation.rows.len - 1));
}
