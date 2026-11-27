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

const Parallel = struct {
    scope: *Scope.Storage,
    allocator: std.mem.Allocator,
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
    var parents = graph.parents();
    const topology: Topology = .{ .graph = &rules.view(Topology, graph), .parents = @ptrCast(&parents) };

    const input: Input = .{
        .topology = &topology,
        .active = &active,
        .incoming = &incoming,
        .parallel = batch != null,
    };

    var buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&buf, arena.allocator());
    const result = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| return errors.errorSet(err);

    for (result.deferred) |item| {
        try graph.pending.binding_collisions.append(graph.pending.allocator, .{
            .left = @fromBackingInt(item.left),
            .right = @fromBackingInt(item.right),
            .span = spans[@intCast(item.row)],
            .message = message,
        });
    }

    if (batch) |out| {
        const count = if (result.conflict_row) |row| @as(usize, @intCast(row)) else incoming.names.len;

        try out.scope.ensureUnusedCapacity(out.allocator, count);

        for (0..count) |index| {
            out.scope.appendAssumeCapacity(.{
                .name = incoming.names[index],
                .value = @fromBackingInt(incoming.values[index]),
                .span = spans[index],
            });
        }
    }

    if (result.conflict_row) |row| {
        return graph.reporter.fail(.name, spans[@intCast(row)], message);
    }
}
