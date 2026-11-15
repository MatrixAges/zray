const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Access = @import("fields/access.zig");
const enabled = @import("rx_options").generated_graph;

pub const Length = struct { target: Graph.Id, value: Graph.Id, span: zx.Span };

pub fn applyLengths(graph: *Graph) zx.Error!void {
    const lengths = graph.pending.lengths.slice();
    const targets = lengths.items(.target);

    if (!enabled) {
        for (targets, 0..) |target, index| {
            const root = graph.root(target);

            if (graph.nodes.items(.kind)[@backingInt(root)] != .Unknown) try applyLength(graph, lengths.get(index), root);
        }

        return;
    }

    const scan = @import("generated_rx_length_replay");
    const Input = std.meta.Child(scan.Input);
    const Known = std.meta.Child(@FieldType(Input, "known"));
    const values = lengths.items(.value);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var start: usize = 0;

    while (start < targets.len) {
        const rows = graph.nodes.slice();
        const types = &graph.types.items;
        const parents = graph.parents();

        const input: Input = .{
            .kinds = rows.items(.kind),
            .arguments = rows.items(.argument),
            .types = &.{
                .kinds = types.kinds.items,
                .first = types.first.items,
                .second = types.second.items,
                .field_names = types.field_names.items,
                .field_types = types.field_types.items,
            },
            .allowed = rows.items(.allowed),
            .parents = @ptrCast(&parents),
            .known = &graph.pending.known_types.borrow(Known),
            .targets = @ptrCast(targets),
            .values = @ptrCast(values),
            .start = start,
        };

        const result = zx.columns.invoke(scan.executeValue, empty.allocator(), &input) catch unreachable;
        const row: usize = @intCast(result.row);

        if (row == targets.len) return;

        const projection = lengths.get(row);

        const value = switch (result.plan.route) {
            .Length, .KnownMember => if (result.node) |node|
                @as(Graph.Id, @fromBackingInt(node))
            else
                try graph.known(@fromBackingInt(result.plan.value), projection.span),
            .RequireList => value: {
                _ = try graph.payload(projection.target, .list, projection.span);

                break :value try graph.scalar(.u64, projection.span);
            },
            .Open => try Access.open(graph, @fromBackingInt(result.root), Access.length_name, projection.span),
            .MissingMember, .InvalidDeclared, .InvalidInferred, .ScalarConflict => return Access.fail(graph, result.plan.route, projection.span),
            else => unreachable,
        };

        try graph.unify(value, projection.value, projection.span);

        start = row + 1;
    }
}

pub fn validateLengths(graph: *Graph) zx.Error!void {
    const lengths = graph.pending.lengths.slice();
    const index = firstPending(graph, lengths.items(.target)) orelse return;

    return graph.reporter.fail(.type_mismatch, lengths.items(.span)[index], "length alone cannot determine whether the input is a list, string or object");
}

pub fn firstPending(graph: *const Graph, targets: []const Graph.Id) ?usize {
    if (targets.len == 0) return null;
    if (!enabled) return seedPending(graph, targets);

    const scan = @import("generated_rx_projection_scan");
    const parents: []u32 = graph.parents();
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(scan.Input) = .{
        .targets = @ptrCast(targets),
        .kinds = graph.nodes.items(.kind),
        .parents = @ptrCast(&parents),
    };

    const result = zx.columns.invoke(scan.executeValue, empty.allocator(), &input) catch unreachable;

    return if (result) |row| @intCast(row) else null;
}

fn applyLength(graph: *Graph, projection: Length, root: Graph.Id) zx.Error!void {
    const value = try Access.at(graph, projection.target, root, Access.length_name, projection.span);

    try graph.unify(value, projection.value, projection.span);
}

fn seedPending(graph: *const Graph, targets: []const Graph.Id) ?usize {
    for (targets, 0..) |target, index| {
        if (graph.shape(target) == .unknown) return index;
    }

    return null;
}
