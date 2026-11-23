const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const enabled = @import("rx_options").generated_graph;
const Self = @This();
pub const Buckets = std.MultiArrayList(struct { metadata: u8, keys: u32, values: u32 });

const State = if (enabled) struct {
    buckets: Buckets.Slice = .empty,
    count: u64 = 0,
} else std.AutoHashMapUnmanaged(zx.ir.TypeId, Graph.Id);

state: State = if (enabled) .{} else .empty,
pub fn borrow(self: *const Self, comptime Table: type) Table {
    return .{
        .count = self.state.count,
        .metadata = self.state.buckets.items(.metadata),
        .keys = self.state.buckets.items(.keys),
        .values = self.state.buckets.items(.values),
    };
}

pub fn get(self: *const Self, type_id: zx.ir.TypeId) ?Graph.Id {
    if (!enabled) return self.state.get(type_id);
    if (self.state.count == 0) return null;

    const rule = @import("generated_rx_known_lookup");
    const Input = std.meta.Child(rule.Input);

    const input: Input = .{
        .known = &self.borrow(std.meta.Child(@FieldType(Input, "known"))),
        .type_id = @backingInt(type_id),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const node = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return @fromBackingInt(node orelse return null);
}

pub fn intern(graph: *Graph, type_id: zx.ir.TypeId, span: zx.Span) zx.Error!Graph.Id {
    if (@backingInt(type_id) >= graph.types.items.count()) return invalid(graph, span);
    if (graph.pending.known_types.get(type_id)) |node| return node;
    if (comptime enabled) return (try register(graph, &.{@backingInt(type_id)}, null, span)).node;

    const node = try graph.add(.{ .known = type_id }, span);

    errdefer graph.nodes.len -= 1;

    try graph.pending.known_types.state.put(graph.pending.allocator, type_id, node);

    return node;
}

pub fn registerMembers(graph: *Graph, types: []const u32, span: zx.Span) zx.Error!void {
    if (types.len != 0) _ = try register(graph, types, null, span);
}

pub const Registration = struct { node: Graph.Id, remaining: u64 };

pub fn registerPayload(graph: *Graph, type_id: u32, remaining: u64, span: zx.Span) zx.Error!Registration {
    return register(graph, &.{type_id}, remaining, span);
}

fn register(graph: *Graph, members: []const u32, budget: ?u64, span: zx.Span) zx.Error!Registration {
    return @import("known/host.zig").register(graph, members, budget, span);
}

pub fn invalid(graph: *Graph, span: zx.Span) zx.Error {
    return graph.reporter.fail(.contract, span, "inference type is outside the shared table");
}
