const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Nodes = @import("nodes.zig");
const enabled = @import("rx_options").generated_graph;
const Self = @This();
const Buckets = std.MultiArrayList(struct { metadata: u8, keys: u32, values: u32 });

const State = if (enabled) struct {
    buckets: Buckets.Slice = .empty,
    count: u64 = 0,
} else std.AutoHashMapUnmanaged(zx.ir.TypeId, Graph.Id);

const Writable = struct {
    metadata: []u8,
    keys: []u32,
    values: []u32,
    fn from(rows: Buckets.Slice) Writable {
        return .{ .metadata = rows.items(.metadata), .keys = rows.items(.keys), .values = rows.items(.values) };
    }
    fn borrow(self: *const Writable, comptime Storage: type) Storage {
        return .{ .metadata = @ptrCast(&self.metadata), .keys = @ptrCast(&self.keys), .values = @ptrCast(&self.values) };
    }
};

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

const Registration = struct { node: Graph.Id, remaining: u64 };

pub fn registerPayload(graph: *Graph, type_id: u32, remaining: u64, span: zx.Span) zx.Error!Registration {
    return register(graph, &.{type_id}, remaining, span);
}

fn register(graph: *Graph, members: []const u32, budget: ?u64, span: zx.Span) zx.Error!Registration {
    const table = &graph.pending.known_types;
    const rule = @import("generated_rx_known_register");
    const Input = std.meta.Child(rule.Input);
    const Row = std.meta.Child(@FieldType(Input, "nodes"));
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var next: u64 = 0;
    var type_id = members[0];
    var remaining = budget;

    while (true) {
        const first = graph.nodes.len;
        var rows = graph.nodes.slice();
        rows.len = graph.nodes.capacity;
        const columns = Nodes.writable(rows);
        const parents = rows.items(.parent);
        const storage = Writable.from(table.state.buckets);

        const input: Input = .{
            .table = &table.borrow(std.meta.Child(@FieldType(Input, "table"))),
            .storage = &storage.borrow(std.meta.Child(@FieldType(Input, "storage"))),
            .nodes = &.{ .parents = @ptrCast(&parents), .columns = &columns.borrow(std.meta.Child(@FieldType(Row, "columns"))), .capacity = rows.len, .known_kind = @backingInt(Nodes.Kind.Known) },
            .members = members,
            .types = &.{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items },
            .type_id = type_id,
            .remaining = remaining,
            .next = next,
            .end = first,
        };

        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        if (result.end != first) {
            rows.len = @intCast(result.end);

            const reservation: Nodes.Reservation = .{ .rows = rows, .first = first };

            reservation.publish(graph, span);

            table.state.count += rows.len - first;
        }

        switch (result.action) {
            .Scan => return .{ .node = @fromBackingInt(result.value), .remaining = result.remaining orelse 0 },
            .Invalid => return invalid(graph, span),
            .Overflow => return error.OutOfMemory,
            .Reserve => {
                if (graph.nodes.len == graph.nodes.capacity) _ = try Nodes.reserve(graph, 1);
                if (result.capacity != table.state.buckets.len) try table.grow(graph.pending.allocator, result.capacity);

                next = result.next;
                type_id = result.type_id;
                remaining = result.remaining;
            },
        }
    }
}

fn grow(self: *Self, allocator: std.mem.Allocator, capacity: u64) std.mem.Allocator.Error!void {
    const rule = @import("generated_rx_known_rehash");
    const Input = std.meta.Child(rule.Input);
    const size = std.math.cast(u32, capacity) orelse return error.OutOfMemory;

    if (size > std.math.maxInt(usize) / Buckets.capacityInBytes(1)) return error.OutOfMemory;

    var fresh: Buckets = .empty;

    try fresh.setCapacity(allocator, size);

    fresh.len = size;
    const rows = fresh.toOwnedSlice();
    const storage = Writable.from(rows);

    const input: Input = .{
        .previous = &self.borrow(std.meta.Child(@FieldType(Input, "previous"))),
        .metadata = storage.metadata,
        .keys = storage.keys,
        .storage = &storage.borrow(std.meta.Child(@FieldType(Input, "storage"))),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    self.state.buckets.deinit(allocator);

    self.state.buckets = rows;
}

fn invalid(graph: *Graph, span: zx.Span) zx.Error {
    return graph.reporter.fail(.contract, span, "inference type is outside the shared table");
}
