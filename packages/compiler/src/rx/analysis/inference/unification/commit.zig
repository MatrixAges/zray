const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Restriction = @import("../scalar/restriction.zig");
const seed = @import("../scalar/seed.zig");
pub const Constraints = struct { allowed: ?u16, fallback: ?u8 };

pub fn publish(graph: *Graph, parent: Graph.Id, child: Graph.Id, first: Constraints, second: Constraints, shape: Nodes.Encoded, span: zx.Span) zx.Error!void {
    const p = @backingInt(parent);
    const c = @backingInt(child);
    const rows = graph.nodes.slice();

    rows.items(.kind)[p] = shape.kind;
    rows.items(.argument)[p] = shape.argument;
    rows.items(.members)[p] = shape.members;

    const parents = graph.parents();

    if (p != c) parents[c] = p;

    const generated = @import("generated_rx_unification_commit");
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const outcome = zx.columns.invoke(generated.executeValue, empty.allocator(), &.{
        .graph = &Restriction.borrow(graph, parents),
        .parent = p,
        .left = &.{
            .allowed = if (first.allowed) |mask| @as(u64, mask) else null,
            .fallback = if (first.fallback) |code| @as(u32, code) else null,
        },
        .right = &.{
            .allowed = if (second.allowed) |mask| @as(u64, mask) else null,
            .fallback = if (second.fallback) |code| @as(u32, code) else null,
        },
    }) catch unreachable;

    rows.items(.fallback)[p] = outcome.fallback;

    if (outcome.allowed) |mask| rows.items(.allowed)[p] = mask;

    graph.revision += 1;
    graph.object_revision += 1;

    if (outcome.message) |text| return graph.reporter.fail(.type_mismatch, span, text);
}

pub fn publishSeed(graph: *Graph, parent: Graph.Id, child: Graph.Id, first: Graph.Node, second: Graph.Node, shape: Graph.Shape, span: zx.Span) zx.Error!void {
    graph.setShape(@backingInt(parent), shape);
    graph.parents()[@backingInt(child)] = @backingInt(parent);

    const constraints = seed.combine(
        .{ .allowed = first.allowed, .fallback = first.fallback },
        .{ .allowed = second.allowed, .fallback = second.fallback },
    );

    graph.nodes.items(.fallback)[@backingInt(parent)] = if (constraints.fallback) |scalar| @backingInt(scalar) else null;

    graph.revision += 1;
    graph.object_revision += 1;

    if (constraints.allowed) |mask| try graph.restrict(parent, mask, span);
}
