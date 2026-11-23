const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Payloads = @import("classes/payloads.zig");
const Self = @This();

parents: []const u32,
representatives: []const ?u32,

payloads: Payloads.Columns = .{},
pub fn init(graph: *Graph, allocator: std.mem.Allocator) zx.Error!Self {
    return if (@import("rx_options").generated_graph)
        build(graph, allocator)
    else
        seed(graph, allocator);
}

fn build(graph: *Graph, allocator: std.mem.Allocator) zx.Error!Self {
    const generated = @import("generated_assignment_classes");
    const payloads = try Payloads.collect(graph, allocator);
    const rows = graph.nodes.slice();
    const edges = graph.pending.assignments.slice();
    const parents = try allocator.alloc(u32, rows.len);
    const representatives = try allocator.alloc(?u32, rows.len);
    const ranks = try allocator.alloc(u8, rows.len);

    defer allocator.free(ranks);

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    generated.executeValue(empty.allocator(), &.{
        .payloads = &.{ .initial = payloads.initial, .registered = payloads.registered },
        .nodes = &.{ .kinds = rows.items(.kind), .allowed = rows.items(.allowed) },
        .edges = &.{ .left = @ptrCast(edges.items(.value)), .right = @ptrCast(edges.items(.expected)) },
        .storage = &.{ .parents = @ptrCast(&parents), .ranks = @ptrCast(&ranks), .representatives = @ptrCast(&representatives) },
        .parents = parents,
        .ranks = ranks,
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .parents = parents, .representatives = representatives, .payloads = payloads };
}

fn seed(graph: *Graph, allocator: std.mem.Allocator) zx.Error!Self {
    var index: usize = 0;

    while (index < graph.nodes.len) : (index += 1) _ = try payload(graph, @fromBackingInt(@intCast(index)));

    const parents = try allocator.alloc(u32, graph.nodes.len);
    const representatives = try allocator.alloc(?u32, parents.len);

    for (parents, 0..) |*parent, item| parent.* = @intCast(item);

    @memset(representatives, null);

    const edges = graph.pending.assignments.slice();

    for (edges.items(.value), edges.items(.expected)) |value, expected| {
        const left = root(parents, @backingInt(try payload(graph, value)));
        const right = root(parents, @backingInt(try payload(graph, expected)));

        parents[right] = left;
    }

    for (0..graph.nodes.len) |item| {
        const id: Graph.Id = @fromBackingInt(@intCast(item));
        const base = try payload(graph, id);
        const index_of_base = @backingInt(base);
        const rows = graph.nodes.slice();

        if (rows.items(.kind)[index_of_base] == .Unknown and rows.items(.allowed)[index_of_base] == null) continue;

        representatives[root(parents, @backingInt(base))] = @backingInt(base);
    }

    for (parents, 0..) |*parent, item| parent.* = root(parents, @intCast(item));

    return .{ .parents = parents, .representatives = representatives };
}

fn root(parents: []u32, index: u32) u32 {
    var current = index;

    while (parents[current] != current) {
        const grandparent = parents[parents[current]];

        parents[current] = grandparent;
        current = grandparent;
    }

    return current;
}

pub fn representative(self: Self, graph: *Graph, id: Graph.Id) zx.Error!?Graph.Id {
    return self.lookup(@backingInt(try payload(graph, id)));
}

fn lookup(self: Self, index: usize) ?Graph.Id {
    const value = self.representatives[self.parents[index]] orelse return null;

    return @fromBackingInt(value);
}

/// Unifies every root with its class representative in one pass instead of one pair per rebuilt base. A
/// representative whose payload changed during the pass waits for the next round's fresh base.
pub fn propagate(self: Self, graph: *Graph) zx.Error!void {
    if (!@import("rx_options").generated_graph) return self.seedPropagate(graph);

    return @import("application/host.zig").propagate(graph, self);
}

fn seedPropagate(self: Self, graph: *Graph) zx.Error!void {
    for (0..self.parents.len) |index| {
        const id: Graph.Id = @fromBackingInt(@intCast(index));

        if (graph.root(id) != id) continue;

        const node = graph.nodeAt(index);

        if (node.shape == .optional or (node.shape == .known and graph.types.get(node.shape.known) == .optional)) continue;
        if (node.shape == .unknown and node.allowed == null) continue;

        const other = self.lookup(index) orelse continue;

        if (graph.root(other) == id) continue;
        if (try payload(graph, other) != graph.root(other)) continue;
        try graph.unify(id, other, node.span);
    }
}

pub const payload = @import("../optional.zig").payload;
