const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Edges = std.MultiArrayList(@import("../assignment.zig").Edge);
const enabled = @import("rx_options").generated_graph;
const Index = if (enabled) []u32 else std.AutoHashMapUnmanaged([2]Graph.Id, void);

pub const Targets = union(enum) {
    repeated: Graph.Id,
    inferred: []const u32,
    declared: []const u32,
};

index: Index = if (enabled) &.{} else .empty,
pub fn expect(graph: *Graph, value: Graph.Id, expected: Graph.Id, span: zx.Span) zx.Error!void {
    if (!enabled) return seed(graph, value, expected, span);

    const register = @import("generated_rx_assignment_register");
    const Input = std.meta.Child(register.Input);
    const registry = &graph.pending.assignment_keys;
    const pending = &graph.pending.assignments;
    const parents = graph.parents();
    const position = pending.len;
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    while (true) {
        const reserved = writable(pending);
        const output = rowBuffers(reserved, registry.index);

        const input: Input = .{
            .endpoints = &.{ .parents = @ptrCast(&parents), .left = @backingInt(value), .right = @backingInt(expected) },
            .keys = output.keys,
            .buckets = output.buckets,
            .rows = &output.rows(std.meta.Child(@FieldType(Input, "rows")), position),
        };

        const result = zx.columns.invoke(register.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        switch (result.action) {
            .Skip => return,
            .Register => unreachable,
            .Overflow => return error.OutOfMemory,
            .Added => {
                reserved.items(.span)[position] = span;

                pending.len += 1;
                graph.revision += 1;

                return;
            },
            .Reserve => try reserve(graph, result.capacity),
        }
    }
}

pub fn expectMany(graph: *Graph, values: []const Graph.Id, spans: []const zx.Span, targets: Targets) zx.Error!void {
    const members: []const u32 = switch (targets) {
        .inferred, .declared => |ids| ids,
        .repeated => &.{},
    };

    std.debug.assert(values.len == spans.len);
    std.debug.assert(targets == .repeated or values.len == members.len);

    const entry = @import("generated_rx_assignment_series");
    const Input = std.meta.Child(entry.Input);
    const Known = std.meta.Child(@typeInfo(@FieldType(Input, "known")).optional.child);
    const pending = &graph.pending.assignments;
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var next: usize = 0;

    while (next < values.len) {
        const reserved = writable(pending);
        const output = rowBuffers(reserved, graph.pending.assignment_keys.index);
        const output_spans = std.mem.sliceAsBytes(reserved.items(.span));
        const parents = graph.parents();
        const known = if (targets == .declared) graph.pending.known_types.borrow(Known) else undefined;

        const request: Input = .{
            .parents = @ptrCast(&parents),
            .keys = output.keys,
            .buckets = output.buckets,
            .rows = &output.rows(std.meta.Child(@FieldType(Input, "rows")), pending.len),
            .values = @ptrCast(values),
            .targets = members,
            .repeated = if (targets == .repeated) @backingInt(targets.repeated) else null,
            .known = if (targets == .declared) &known else null,
            .spans = &.{ .source = std.mem.sliceAsBytes(spans), .target = @ptrCast(&output_spans), .width = @sizeOf(zx.Span) },
            .next = next,
        };

        const result = zx.columns.invoke(entry.executeValue, empty.allocator(), &request) catch unreachable;
        const previous = pending.len;
        pending.len = @intCast(result.position);
        graph.revision += pending.len - previous;
        next = @intCast(result.next);

        switch (result.action) {
            .Skip => return,
            .Overflow => return error.OutOfMemory,
            .Reserve => try reserve(graph, result.capacity),
            .Register => _ = try graph.known(@fromBackingInt(members[next]), spans[next]),
            .Added => unreachable,
        }
    }
}

fn writable(pending: *const Edges) Edges.Slice {
    var reserved = pending.slice();

    reserved.len = reserved.capacity;

    return reserved;
}

const Buffers = struct {
    left: []u32,
    right: []u32,
    keys: []u64,
    buckets: []u32,
    fn rows(self: *const Buffers, comptime Row: type, position: usize) Row {
        return .{
            .left = @ptrCast(&self.left),
            .right = @ptrCast(&self.right),
            .keys = @ptrCast(&self.keys),
            .buckets = @ptrCast(&self.buckets),
            .position = position,
            .capacity = self.keys.len,
        };
    }
};

fn rowBuffers(reserved: Edges.Slice, buckets: []u32) Buffers {
    return .{
        .left = @ptrCast(reserved.items(.value)),
        .right = @ptrCast(reserved.items(.expected)),
        .keys = reserved.items(.key),
        .buckets = buckets,
    };
}

fn reserve(graph: *Graph, bucket_count: u64) std.mem.Allocator.Error!void {
    const allocator = graph.pending.allocator;
    const pending = &graph.pending.assignments;
    const registry = &graph.pending.assignment_keys;
    const previous = registry.index;

    try pending.ensureUnusedCapacity(allocator, 1);
    if (bucket_count <= previous.len) return;

    const capacity = std.math.cast(usize, bucket_count) orelse return error.OutOfMemory;

    registry.index = try rebuild(allocator, pending.items(.key), capacity);

    allocator.free(previous);
}

fn rebuild(allocator: std.mem.Allocator, keys: []const u64, capacity: usize) std.mem.Allocator.Error![]u32 {
    const buckets = try allocator.alloc(u32, capacity);

    @memset(buckets, std.math.maxInt(u32));

    const entry = @import("generated_rx_assignment_rebuild");
    const input: std.meta.Child(entry.Input) = .{ .keys = keys, .buckets = buckets, .target = @ptrCast(&buckets) };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

    return buckets;
}

fn seed(graph: *Graph, value: Graph.Id, expected: Graph.Id, span: zx.Span) zx.Error!void {
    const key = [2]Graph.Id{ graph.root(value), graph.root(expected) };

    if (key[0] == key[1] or graph.pending.assignment_keys.index.contains(key)) return;
    try graph.pending.assignments.ensureUnusedCapacity(graph.pending.allocator, 1);
    try graph.pending.assignment_keys.index.put(graph.pending.allocator, key, {});

    graph.pending.assignments.appendAssumeCapacity(.{ .value = key[0], .expected = key[1], .span = span });

    graph.revision += 1;
}
