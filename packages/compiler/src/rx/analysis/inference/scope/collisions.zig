const std = @import("std");
const zx = @import("zx");
const Scope = @import("../scope.zig");
const Graph = @import("../types.zig");
const rules = @import("../bindings/rules.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_scope_register");
const Input = std.meta.Child(entry.Input);
const Topology = std.meta.Child(@FieldType(Input, "topology"));
const Active = std.meta.Child(@FieldType(Input, "active"));
const Columns = std.meta.Child(@FieldType(Input, "storage"));
const Spans = std.meta.Child(@FieldType(Columns, "spans"));
const Bindings = std.meta.Child(@typeInfo(@FieldType(Input, "batch")).optional.child);

const Parallel = struct {
    scope: *Scope.Storage,
    allocator: std.mem.Allocator,
};

const Frame = struct {
    graph: *Graph,
    spans: []const zx.Span,
    message: []const u8,
    batch: ?Parallel,
    columns: Columns = undefined,
    source: Spans = undefined,
    left: []u32 = undefined,
    right: []u32 = undefined,
    messages: [][]const u8 = undefined,
    pair_spans: []u8 = undefined,
    pair_length: []usize = undefined,
    binding_names: [][]const u8 = undefined,
    binding_values: []u32 = undefined,
    binding_spans: []u8 = undefined,
    binding_length: []usize = undefined,
    bindings: Bindings = undefined,
    fn bindPairs(self: *Frame) void {
        var rows = self.graph.pending.binding_collisions.slice();

        rows.len = rows.capacity;
        self.left = @ptrCast(rows.items(.left));
        self.right = @ptrCast(rows.items(.right));
        self.messages = rows.items(.message);
        self.pair_spans = std.mem.sliceAsBytes(rows.items(.span));
        self.columns.capacity = rows.len;
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn check(graph: *Graph, rows: Scope.Storage.Slice, end: usize, binding: Scope.Binding, message: []const u8) zx.Error!void {
    const active: Active = .{ .names = rows.items(.name)[0..end], .values = @ptrCast(rows.items(.value)[0..end]) };
    const incoming: Active = .{ .names = &.{binding.name}, .values = &.{@backingInt(binding.value)} };

    try register(graph, active, incoming, &.{binding.span}, message, null);
}

pub fn parallel(graph: *Graph, scope: *Scope.Storage, allocator: std.mem.Allocator, saved: Scope.Storage.Slice, message: []const u8) zx.Error!void {
    if (saved.len == 0) return;

    const active: Active = .{ .names = saved.items(.name), .values = @ptrCast(saved.items(.value)) };

    try register(graph, active, active, saved.items(.span), message, .{ .scope = scope, .allocator = allocator });
}

fn register(graph: *Graph, active: Active, incoming: Active, spans: []const zx.Span, message: []const u8, batch: ?Parallel) zx.Error!void {
    const pairs = &graph.pending.binding_collisions;
    var parents = graph.parents();
    const topology: Topology = .{ .graph = &rules.view(Topology, graph), .parents = @ptrCast(&parents) };
    var frame: Frame = .{ .graph = graph, .spans = spans, .message = message, .batch = batch };
    frame.pair_length = (&pairs.len)[0..1];
    frame.source = .{ .source = std.mem.sliceAsBytes(spans), .target = @ptrCast(&frame.pair_spans), .width = @sizeOf(zx.Span) };

    frame.columns = .{
        .left = @ptrCast(&frame.left),
        .right = @ptrCast(&frame.right),
        .messages = @ptrCast(&frame.messages),
        .message = message,
        .spans = &frame.source,
        .capacity = undefined,
    };

    frame.bindPairs();

    if (batch) |out| {
        frame.binding_length = (&out.scope.len)[0..1];

        frame.bindings = .{
            .names = @ptrCast(&frame.binding_names),
            .values = @ptrCast(&frame.binding_values),
            .spans = @ptrCast(&frame.binding_spans),
            .length = @ptrCast(&frame.binding_length),
        };
    }

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .topology = &topology,
        .active = &active,
        .incoming = &incoming,
        .storage = &frame.columns,
        .length = @ptrCast(&frame.pair_length),
        .count = pairs.len,
        .batch = if (batch != null) &frame.bindings else null,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn reserveScopeCollisions(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;

    try pending.binding_collisions.ensureUnusedCapacity(pending.allocator, 1);

    frame.bindPairs();
}

pub fn reserveScopeBindings(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);
    const batch = frame.batch.?;
    const first = batch.scope.len;
    const additional = std.math.cast(usize, count) orelse return error.OutOfMemory;

    try batch.scope.ensureUnusedCapacity(batch.allocator, additional);

    var rows = batch.scope.slice();

    rows.len = first + additional;
    frame.binding_names = rows.items(.name);
    frame.binding_values = @ptrCast(rows.items(.value));
    frame.binding_spans = std.mem.sliceAsBytes(rows.items(.span));

    return first;
}

pub fn rejectScopeCollision(handle: *const anyopaque, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frame.graph.reporter.fail(.name, frame.spans[@intCast(row)], frame.message);
}
