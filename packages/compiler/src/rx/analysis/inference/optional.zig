const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const seed = @import("optional/seed.zig");
const enabled = @import("rx_options").generated_graph;
const rule = if (enabled) @import("generated_rx_optional_query") else void;

pub fn guarded(graph: *Graph, source: Graph.Id, span: zx.Span) zx.Error!?Graph.Id {
    return if (enabled) query(.Guard, graph, source, span) else seed.guarded(graph, source, span);
}

pub fn hint(graph: *Graph, source: Graph.Id) zx.Error!?Graph.Id {
    return if (enabled) query(.Hint, graph, source, null) else seed.hint(graph, source);
}

pub fn payload(graph: *Graph, source: Graph.Id) zx.Error!Graph.Id {
    return if (enabled) (try query(.Payload, graph, source, null)).? else seed.payload(graph, source);
}

fn query(comptime mode: @FieldType(std.meta.Child(rule.Input), "mode"), graph: *Graph, source: Graph.Id, guard_span: ?zx.Span) zx.Error!?Graph.Id {
    const Input = std.meta.Child(rule.Input);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var value = source;
    var remaining: ?u64 = null;

    while (true) {
        const rows = graph.nodes.slice();
        const parents = graph.parents();
        const types = &graph.types.items;

        const input: Input = .{
            .mode = mode,
            .graph = &.{ .kinds = rows.items(.kind), .arguments = rows.items(.argument), .types = &.{ .kinds = types.kinds.items, .children = types.first.items } },
            .known = &graph.pending.known_types.borrow(std.meta.Child(@FieldType(Input, "known"))),
            .parents = @ptrCast(&parents),
            .allowed = rows.items(.allowed),
            .value = @backingInt(value),
            .remaining = remaining,
        };

        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        switch (result.action) {
            .Ready => return if (result.value) |id| @fromBackingInt(id) else null,
            .Register => {
                const span = guard_span orelse rows.items(.span)[result.root];
                const registered = try @import("known.zig").registerPayload(graph, result.value.?, result.remaining, span);

                if (mode == .Guard) return registered.node;

                value = registered.node;
                remaining = registered.remaining;
            },
            .Depth => return graph.reporter.fail(.unsupported, rows.items(.span)[result.root], "type inference nesting exceeds 256 levels"),
            .Continue => unreachable,
        }
    }
}
