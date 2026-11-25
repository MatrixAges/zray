const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Projection = @import("../index.zig").Projection;
const Target = @import("../sequences/target.zig");
const errors = @import("../../project/workflow/errors.zig");
const rule = @import("generated_rx_resolve_index");
const Input = std.meta.Child(rule.Input);

pub fn register(graph: *Graph, pending: Projection) zx.Error!void {
    const view = Target.borrow(std.meta.Child(@FieldType(Input, "graph")), graph);

    const site = std.meta.Child(@FieldType(Input, "site")){
        .graph = @ptrCast(graph),
        .spans = @ptrCast(&@as([]const zx.Span, (&pending.span)[0..1])),
        .row = 0,
    };

    const input: Input = .{
        .site = &site,
        .index_spans = @ptrCast(&@as([]const zx.Span, (&pending.index_span)[0..1])),
        .graph = &view,
        .target = @backingInt(pending.target),
        .root = @backingInt(graph.root(pending.target)),
        .value = @backingInt(pending.value),
        .position = pending.position,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    _ = rule.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn appendIndexProjection(handle: *anyopaque, spans: *const anyopaque, index_spans: *const anyopaque, target: u32, value: u32, position: ?u64) std.mem.Allocator.Error!void {
    const graph: *Graph = @ptrCast(@alignCast(handle));
    const span: *const []const zx.Span = @ptrCast(@alignCast(spans));
    const index_span: *const []const zx.Span = @ptrCast(@alignCast(index_spans));

    try graph.pending.indexes.append(graph.pending.allocator, .{
        .target = @fromBackingInt(target),
        .value = @fromBackingInt(value),
        .position = position,
        .span = span.*[0],
        .index_span = index_span.*[0],
    });
}
