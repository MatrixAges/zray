const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Known = @import("../known.zig");
const Buckets = Known.Buckets;
const rule = @import("generated_rx_register_known_types");
const Input = std.meta.Child(rule.Input);
const Registry = std.meta.Child(@FieldType(Input, "view"));
const Table = std.meta.Child(@FieldType(Registry, "table"));

const Frame = struct {
    graph: *Graph,
    span: zx.Span,
    table: Table = undefined,
    registry: Registry = undefined,
    fn bind(self: *Frame) void {
        self.table = self.graph.pending.known_types.borrow(Table);
    }
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn register(graph: *Graph, members: []const u32, budget: ?u64, span: zx.Span) zx.Error!Known.Registration {
    var frame: Frame = .{ .graph = graph, .span = span };

    frame.bind();

    frame.registry = .{ .table = &frame.table };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .view = &frame.registry,
        .types = &.{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items },
        .members = members,
        .type_id = members[0],
        .remaining = budget,
        .end = graph.nodes.len,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../../project/workflow/errors.zig");
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| return workflow.errorSet(err);

    return .{ .node = @fromBackingInt(result.value), .remaining = result.remaining orelse 0 };
}

pub fn commitKnownNode(handle: *anyopaque, slot: u64, tag: u8, type_id: u32) std.mem.Allocator.Error!u32 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;

    const created = Nodes.append(graph, .{ .known = @fromBackingInt(type_id) }, frame.span) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const node = @backingInt(created);
    const table = &graph.pending.known_types;
    const index: usize = @intCast(slot);

    table.state.buckets.items(.metadata)[index] = tag;
    table.state.buckets.items(.keys)[index] = type_id;
    table.state.buckets.items(.values)[index] = node;

    table.state.count += 1;

    frame.bind();

    return node;
}

pub fn reserveKnownIndex(handle: *anyopaque, capacity: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const table = &graph.pending.known_types;
    const allocator = graph.pending.allocator;
    const rehash = @import("generated_rx_known_rehash");
    const RehashInput = std.meta.Child(rehash.Input);
    const size = std.math.cast(u32, capacity) orelse return error.OutOfMemory;

    if (size > std.math.maxInt(usize) / Buckets.capacityInBytes(1)) return error.OutOfMemory;

    var fresh: Buckets = .empty;

    try fresh.setCapacity(allocator, size);

    fresh.len = size;
    const rows = fresh.toOwnedSlice();

    const input: RehashInput = .{
        .previous = &table.borrow(std.meta.Child(@FieldType(RehashInput, "previous"))),
        .capacity = capacity,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const result = zx.columns.invoke(rehash.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    @memcpy(rows.items(.metadata), result.metadata);
    @memcpy(rows.items(.keys), result.keys);
    @memcpy(rows.items(.values), result.values);
    table.state.buckets.deinit(allocator);

    table.state.buckets = rows;

    frame.bind();
}

pub fn rejectKnownType(handle: *anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);

    return Known.invalid(frame.graph, frame.span);
}
