const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const rules = @import("rules.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_require_binding_value");
const Input = std.meta.Child(entry.Input);
const Topology = std.meta.Child(@FieldType(Input, "topology"));

pub fn run(graph: *Graph, value: Graph.Id, span: zx.Span) zx.Error!void {
    var parents = graph.parents();
    const source: []const zx.Span = &.{span};

    const input: Input = .{
        .topology = &.{ .graph = &rules.view(Topology, graph), .parents = @ptrCast(&parents) },
        .value = @backingInt(value),
        .reporter = @ptrCast(graph.reporter),
        .source = @ptrCast(&source),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const pending = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch |err| return errors.errorSet(err);

    if (pending) try graph.pending.value_uses.append(graph.pending.allocator, .{ .value = value, .span = span });
}
