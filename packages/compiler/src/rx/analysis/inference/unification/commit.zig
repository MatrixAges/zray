const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Restriction = @import("../scalar/restriction.zig");
const seed = @import("../scalar/seed.zig");
pub const Constraints = struct { allowed: ?u16, fallback: ?u8 };

pub fn snapshot(rows: Nodes.Storage.Slice, id: Graph.Id) Constraints {
    const index = @backingInt(id);

    return .{ .allowed = rows.items(.allowed)[index], .fallback = rows.items(.fallback)[index] };
}

pub fn publish(graph: *Graph, parent: Graph.Id, child: Graph.Id, first: Constraints, second: Constraints, shape: Nodes.Encoded, span: zx.Span) zx.Error!void {
    const generated = @import("generated_rx_unification_commit");
    const parents: []u32 = graph.parents();
    const Input = std.meta.Child(generated.Input);
    const Columns = std.meta.Child(@FieldType(Input, "columns"));
    const rows = Nodes.writable(graph.nodes.slice());
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const result = generated.executeValue(scratch.allocator(), &.{
        .parents = @ptrCast(&parents),
        .graph = &Restriction.borrow(graph, &parents),
        .parent = @backingInt(parent),
        .child = @backingInt(child),
        .columns = &rows.borrow(Columns),
        .shape = &.{ .kind = @backingInt(shape.kind), .argument = shape.argument, .members = shape.members },
        .left = &.{
            .allowed = if (first.allowed) |mask| @as(u64, mask) else null,
            .fallback = if (first.fallback) |code| @as(u32, code) else null,
        },
        .right = &.{
            .allowed = if (second.allowed) |mask| @as(u64, mask) else null,
            .fallback = if (second.fallback) |code| @as(u32, code) else null,
        },
    }) catch unreachable;

    graph.nodes.items(.fallback)[@backingInt(parent)] = if (result.fallback) |code| @intCast(code) else null;

    graph.revision += 1;
    graph.object_revision += 1;

    if (result.restriction) |restriction| try Restriction.apply(graph, restriction, span);
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
