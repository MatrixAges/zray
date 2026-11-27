const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Publication = @import("../scalar/restriction.zig").Publication;
const rule = @import("generated_rx_inference_number");

pub fn append(graph: *Graph, text: []const u8, negative: bool, span: zx.Span) zx.Error!Graph.Id {
    const reservation = try Nodes.reserve(graph, 1);
    const Input = std.meta.Child(rule.Input);
    const Rows = std.meta.Child(@FieldType(Input, "rows"));
    var parents = reservation.rows.items(.parent);
    var topology = Nodes.writable(reservation.rows);
    var publication = Publication.init(reservation.rows);
    var visibility = Nodes.Publication.init(graph, reservation.rows);

    const input: Input = .{
        .rows = &.{
            .first = reservation.first,
            .end = reservation.rows.len,
            .parents = @ptrCast(&parents),
            .columns = &topology.borrow(std.meta.Child(@FieldType(Rows, "columns"))),
            .shape = &.{ .kind = @backingInt(Nodes.Kind.Unknown), .argument = 0, .members = &.{} },
        },
        .storage = &publication.borrow(std.meta.Child(@FieldType(Input, "storage"))),
        .length = @ptrCast(&visibility.length),
        .span = &visibility.span(std.meta.Child(@FieldType(Input, "span")), span),
        .token = &.{ .text = text, .negative = negative },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), &input) catch unreachable;

    graph.revision += 1;

    return @fromBackingInt(@intCast(reservation.first));
}
