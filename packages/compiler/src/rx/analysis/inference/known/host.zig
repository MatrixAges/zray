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
const Store = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Effect = std.meta.Child(Store);
const Execution = @import("../../project/workflow/execute.zig");

const Frame = struct {
    graph: *Graph,
    span: zx.Span,
    table: Table = undefined,
    registry: Registry = undefined,
    fn bind(self: *Frame) void {
        self.table = self.graph.pending.known_types.borrow(Table);
    }
};

pub fn register(graph: *Graph, members: []const u32, budget: ?u64, span: zx.Span) zx.Error!Known.Registration {
    var frame: Frame = .{ .graph = graph, .span = span };

    frame.bind();

    frame.registry = .{ .table = &frame.table };

    const input: Input = .{
        .view = &frame.registry,
        .types = &.{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items },
        .members = members,
        .type_id = members[0],
        .remaining = budget,
        .end = graph.nodes.len,
    };

    const Host = struct {
        frame: *Frame,
        store_0: *Store,
        pub fn commit(host: *@This(), pending: rule.zx_pending) zx.Error!void {
            const command = pending.store_0 orelse return;
            const current = host.frame;

            switch (command.step) {
                .Overflow => return error.OutOfMemory,
                .Insert => try commitKnownNode(current, command.slot.?, command.tag.?, command.type_id.?),
                .Replace => try replaceKnownIndex(current, command.buckets.?),
                .Reject => return Known.invalid(current.graph, current.span),
            }
        }
    };

    const initial = Execution.snapshot(Effect, .{ .step = .Insert });
    var store: Store = &initial;
    var host: Host = .{ .frame = &frame, .store_0 = &store };
    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var bytes: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&bytes, arena.allocator());
    const workflow = @import("../../project/workflow/errors.zig");

    const result = rule.executeIn(scratch.allocator(), &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return workflow.errorSet(err),
    };

    return .{ .node = @fromBackingInt(result.value), .remaining = result.remaining orelse 0 };
}

fn commitKnownNode(frame: *Frame, slot: u64, tag: u8, type_id: u32) std.mem.Allocator.Error!void {
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
}

fn replaceKnownIndex(frame: *Frame, result: anytype) std.mem.Allocator.Error!void {
    const table = &frame.graph.pending.known_types;
    const allocator = frame.graph.pending.allocator;
    const size = std.math.cast(u32, result.keys.len) orelse return error.OutOfMemory;

    if (size > std.math.maxInt(usize) / Buckets.capacityInBytes(1)) return error.OutOfMemory;

    var fresh: Buckets = .empty;

    try fresh.setCapacity(allocator, size);

    fresh.len = size;

    const rows = fresh.toOwnedSlice();

    @memcpy(rows.items(.metadata), result.metadata);
    @memcpy(rows.items(.keys), result.keys);
    @memcpy(rows.items(.values), result.values);
    table.state.buckets.deinit(allocator);

    table.state.buckets = rows;

    frame.bind();
}
