const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const enabled = @import("rx_options").generated_graph;
const writing = if (enabled) @import("generated_rx_known_put") else void;

const State = if (enabled)
    @typeInfo(@typeInfo(@TypeOf(writing.executeState)).@"fn".return_type.?).error_union.payload

else
    std.AutoHashMapUnmanaged(zx.ir.TypeId, Graph.Id);

const Self = @This();

state: State = if (enabled) .{
    .count = 0,
    .metadata = .{ .items = &.{}, .storage = .plain },
    .keys = .{ .items = &.{}, .storage = .plain },
    .values = .{ .items = &.{}, .storage = .plain },
} else .empty,
pub fn borrow(self: *const Self, comptime Table: type) Table {
    return .{
        .count = self.state.count,
        .metadata = self.state.metadata.items,
        .keys = self.state.keys.items,
        .values = self.state.values.items,
    };
}

pub fn get(self: *const Self, type_id: zx.ir.TypeId) ?Graph.Id {
    if (!enabled) return self.state.get(type_id);
    if (self.state.count == 0) return null;

    const querying = @import("generated_rx_known_lookup");
    const Input = std.meta.Child(querying.Input);

    const input: Input = .{
        .count = self.state.count,
        .metadata = self.state.metadata.items,
        .keys = self.state.keys.items,
        .key = @backingInt(type_id),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const slot = zx.columns.invoke(querying.executeValue, scratch.allocator(), &input) catch unreachable;

    return @fromBackingInt(self.state.values.items[slot orelse return null]);
}

pub fn intern(graph: *Graph, type_id: zx.ir.TypeId, span: zx.Span) zx.Error!Graph.Id {
    try check(graph, type_id, span);
    if (graph.pending.known_types.get(type_id)) |id| return id;

    return insert(graph, type_id, span);
}

pub fn registerMembers(graph: *Graph, types: []const u32, span: zx.Span) zx.Error!void {
    const missing = @import("generated_rx_known_missing");
    const Input = std.meta.Child(missing.Input);
    const Table = std.meta.Child(@FieldType(Input, "known"));
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    var first: usize = 0;

    while (first < types.len) {
        const table = graph.pending.known_types.borrow(Table);
        const input: Input = .{ .known = &table, .types = types, .first = first };
        const next = zx.columns.invoke(missing.executeValue, scratch.allocator(), &input) catch unreachable;
        const position = next orelse return;
        const type_id: zx.ir.TypeId = @fromBackingInt(types[@intCast(position)]);

        try check(graph, type_id, span);

        _ = try insert(graph, type_id, span);
        first = @intCast(position + 1);
    }
}

fn check(graph: *const Graph, type_id: zx.ir.TypeId, span: zx.Span) zx.Error!void {
    if (@backingInt(type_id) >= graph.types.items.count()) return graph.reporter.fail(.contract, span, "inference type is outside the shared table");
}

fn insert(graph: *Graph, type_id: zx.ir.TypeId, span: zx.Span) zx.Error!Graph.Id {
    const id = try graph.add(.{ .known = type_id }, span);

    graph.pending.known_types.put(graph.pending.allocator, type_id, id) catch |err| {
        graph.nodes.len -= 1;

        return err;
    };

    return id;
}

fn put(self: *Self, allocator: std.mem.Allocator, type_id: zx.ir.TypeId, node: Graph.Id) std.mem.Allocator.Error!void {
    if (!enabled) return self.state.put(allocator, type_id, node);

    const Parameter = @typeInfo(@TypeOf(writing.executeState)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const input: Input = .{ .state = self.state, .key = @backingInt(type_id), .value = @backingInt(node) };

    self.state = writing.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}
