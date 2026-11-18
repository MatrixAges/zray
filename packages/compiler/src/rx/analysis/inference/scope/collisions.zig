const std = @import("std");
const zx = @import("zx");
const Scope = @import("../scope.zig");
const Graph = @import("../types.zig");
const rules = @import("../bindings/rules.zig");
const entry = @import("generated_rx_scope_register");
const Input = std.meta.Child(entry.Input);
const Active = std.meta.Child(@FieldType(Input, "active"));

pub fn check(graph: *Graph, rows: Scope.Storage.Slice, end: usize, binding: Scope.Binding, message: []const u8) zx.Error!void {
    const active: Active = .{ .names = rows.items(.name)[0..end], .values = @ptrCast(rows.items(.value)[0..end]) };
    const incoming: Active = .{ .names = &.{binding.name}, .values = &.{@backingInt(binding.value)} };

    try register(graph, active, incoming, &.{binding.span}, message, null);
}

const Parallel = struct {
    scope: *Scope.Storage,
    allocator: std.mem.Allocator,
    saved: Scope.Storage.Slice,
};

pub fn parallel(graph: *Graph, scope: *Scope.Storage, allocator: std.mem.Allocator, saved: Scope.Storage.Slice, message: []const u8) zx.Error!void {
    const active: Active = .{ .names = saved.items(.name), .values = @ptrCast(saved.items(.value)) };

    try register(graph, active, active, saved.items(.span), message, .{ .scope = scope, .allocator = allocator, .saved = saved });
}

fn register(graph: *Graph, active: Active, incoming: Active, spans: []const zx.Span, message: []const u8, batch: ?Parallel) zx.Error!void {
    const pairs = &graph.pending.binding_collisions;
    const parents = graph.parents();
    const topology: std.meta.Child(@FieldType(Input, "topology")) = .{ .graph = &rules.view(entry, graph), .parents = @ptrCast(&parents) };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var published: usize = 0;
    var row: u64 = if (batch != null) 1 else 0;
    var next: u64 = 0;

    while (true) {
        var rows = pairs.slice();
        rows.len = rows.capacity;
        const left: []u32 = @ptrCast(rows.items(.left));
        const right: []u32 = @ptrCast(rows.items(.right));
        const messages = rows.items(.message);
        const target = std.mem.sliceAsBytes(rows.items(.span));

        const input: Input = .{
            .active = &active,
            .incoming = &incoming,
            .topology = &topology,
            .storage = &.{
                .left = @ptrCast(&left),
                .right = @ptrCast(&right),
                .messages = @ptrCast(&messages),
                .message = message,
                .spans = &.{ .source = std.mem.sliceAsBytes(spans), .target = @ptrCast(&target), .width = @sizeOf(zx.Span) },
                .capacity = rows.len,
            },
            .row = row,
            .next = next,
            .count = pairs.len,
            .published = published,
            .parallel = batch != null,
        };

        const result = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

        pairs.len = @intCast(result.count);
        row = result.row;
        next = result.next;

        if (batch) |outputs| {
            if (row > published) {
                var prefix = outputs.saved;

                prefix.len = @intCast(row);

                try Scope.appendFrom(outputs.scope, outputs.allocator, prefix, published);

                published = prefix.len;
            }
        }

        switch (result.action) {
            .Scan => return,
            .Reserve => try pairs.ensureUnusedCapacity(graph.pending.allocator, 1),
            .Publish => continue,
            .Conflict => return graph.reporter.fail(.name, spans[@intCast(row)], message),
        }
    }
}
