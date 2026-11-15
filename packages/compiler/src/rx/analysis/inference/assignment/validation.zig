const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Edges = std.MultiArrayList(@import("../assignment.zig").Edge).Slice;

pub fn validate(graph: *Graph, resolver: *Graph.Resolver) zx.Error!void {
    const edges = graph.pending.assignments.slice();

    if (!@import("rx_options").generated_graph) return seed(graph, edges);
    if (edges.len == 0) return;

    const generated = @import("generated_assignment_validation");
    const Request = std.meta.Child(generated.Input);
    const View = std.meta.Child(@FieldType(Request, "graph"));
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var index: usize = 0;
    var source: ?u32 = null;
    var resolved: ?u32 = null;

    while (index < edges.len) {
        const rows = graph.nodes.slice();

        const view: View = .{
            .kinds = rows.items(.kind),
            .arguments = rows.items(.argument),
            .types = &.{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items },
        };

        const parents = graph.parents();

        const input: Request = .{
            .graph = &view,
            .edges = &.{ .left = @ptrCast(edges.items(.value)), .right = @ptrCast(edges.items(.expected)) },
            .parents = @ptrCast(&parents),
            .index = index,
            .source_type = source,
            .resolved = resolved,
        };

        const result = zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;

        index = @intCast(result.index);

        switch (result.action) {
            .Scan => return,
            .Resolve => {
                source = result.source_type;
                resolved = @backingInt(try graph.resolve(@fromBackingInt(result.node), resolver));
            },
            .Mismatch => return mismatch(graph, edges.items(.span)[index]),
        }
    }
}

fn seed(graph: *Graph, edges: Edges) zx.Error!void {
    const resolve = @import("../resolve/seed.zig").resolve;

    for (edges.items(.value), edges.items(.expected), edges.items(.span)) |source, target, span| {
        const actual = try resolve(graph, source, 0);
        const expected = try resolve(graph, target, 0);

        if (!seedAccepts(graph.types.items.view(), actual, expected)) return mismatch(graph, span);
    }
}

fn seedAccepts(table: zx.ir.TypeTable, actual: zx.ir.TypeId, expected: zx.ir.TypeId) bool {
    const optional = @backingInt(std.meta.Tag(zx.ir.Type).optional);
    var current = expected;

    while (current != actual) {
        const index = @backingInt(current);

        if (table.kinds[index] != optional) return false;

        current = @fromBackingInt(table.first[index]);
    }

    return true;
}

fn mismatch(graph: *const Graph, span: zx.Span) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, "inferred value cannot be passed to the required type");
}
