const zx = @import("zx");
const Graph = @import("types.zig");
const rules = @import("bindings/rules.zig");
pub const missing_message = "flow value is not defined in this scope";
pub const Use = struct { value: Graph.Id, span: zx.Span };
pub const Collision = struct { left: Graph.Id, right: Graph.Id, span: zx.Span, message: []const u8 };
pub const Lookup = struct { candidates: []const Graph.Id, value: Graph.Id, span: zx.Span };

pub fn isVoid(graph: *const Graph, id: Graph.Id) bool {
    return rules.status(graph, id) == .Void;
}

pub fn requireValue(graph: *Graph, value: Graph.Id, span: zx.Span) zx.Error!void {
    switch (rules.status(graph, value)) {
        .Void => return graph.reporter.fail(.name, span, missing_message),
        .Value => {},
        .Pending => try graph.pending.value_uses.append(graph.pending.allocator, .{ .value = value, .span = span }),
    }
}

pub fn validateUses(graph: *const Graph) zx.Error!void {
    const uses = graph.pending.value_uses.slice();
    const index = rules.missing(graph, uses.items(.value)) orelse return;

    return graph.reporter.fail(.name, uses.items(.span)[index], missing_message);
}

pub fn distinct(graph: *Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, message: []const u8, action: rules.Collision) zx.Error!void {
    switch (action) {
        .Ignore => {},
        .Conflict => return graph.reporter.fail(.name, span, message),
        .Defer => try graph.pending.binding_collisions.append(graph.pending.allocator, .{ .left = left, .right = right, .span = span, .message = message }),
    }
}

/// The caller transfers the candidate buffer on success.
pub fn lookup(graph: *Graph, candidates: []const Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    const value = try graph.add(.unknown, span);

    errdefer graph.nodes.len -= 1;

    try graph.pending.binding_lookups.append(graph.pending.allocator, .{ .candidates = candidates, .value = value, .span = span });

    return value;
}

pub fn propagate(graph: *Graph, final: bool) zx.Error!void {
    if (!@import("rx_options").generated_graph) return seed(graph, final);
    try @import("bindings/host.zig").run(graph, final);
}

fn seed(graph: *Graph, final: bool) zx.Error!void {
    const collisions = graph.pending.binding_collisions.slice();

    for (0..collisions.len) |index| {
        const row = collisions.get(index);

        if (rules.pair(graph, row.left, row.right, final) == .Conflict) return graph.reporter.fail(.name, row.span, row.message);
    }

    const lookups = graph.pending.binding_lookups.slice();

    for (0..lookups.len) |index| {
        const query = lookups.get(index);
        const choice = rules.selectSeed(graph, query.candidates);

        if (choice.multiple) continue;

        const candidate = choice.value orelse return graph.reporter.fail(.name, query.span, missing_message);

        try graph.unify(query.value, candidate, query.span);
    }
}
