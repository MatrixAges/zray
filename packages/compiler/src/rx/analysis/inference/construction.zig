const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const ObjectClosure = @import("object_closure.zig");
const columns = @import("fields/columns.zig");
pub const Part = struct { name: ?[]const u8, value: Graph.Id, span: zx.Span };

pub const Object = struct {
    result: Graph.Id,
    first: u64,
    count: u64,
    span: zx.Span,
    pub fn part(self: Object, graph: *const Graph, index: usize) Part {
        return graph.pending.construction_parts.get(@as(usize, @intCast(self.first)) + index);
    }
};

pub fn replay(graph: *Graph, closure: *ObjectClosure, final: bool) zx.Error!void {
    const objects = graph.pending.constructions.slice();

    if (comptime !@import("rx_options").generated_graph) {
        for (0..objects.len) |row| try @import("construction/seed.zig").propagate(graph, closure, objects.get(row), final);

        return;
    }

    const rule = @import("generated_object_construction_queue");
    const Input = std.meta.Child(rule.Input);
    const Columns = std.meta.Child(@FieldType(Input, "columns"));
    const results = objects.items(.result);
    const parts = objects.items(.count);
    var first: usize = 0;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (first < objects.len) {
        const parents = graph.parents();

        const input: Input = .{
            .columns = &columns.borrow(Columns, graph),
            .parents = @ptrCast(&parents),
            .results = @ptrCast(results),
            .parts = parts,
            .first = first,
        };

        const next = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        const row: usize = @intCast(next.position);

        if (row == objects.len) return;

        try @import("construction/project.zig").propagate(graph, closure, objects.get(row), @fromBackingInt(next.root), @fromBackingInt(@backingInt(next.mode)), final);

        first = row + 1;
    }
}
