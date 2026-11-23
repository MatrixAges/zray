const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("types.zig");
const Expression = @import("expression.zig");
const Target = @import("sequences/target.zig");
const Projections = @import("projections.zig");
const Schedule = @import("expression/schedule.zig");

pub const Projection = struct { target: Graph.Id, value: Graph.Id, position: ?u64, span: zx.Span, index_span: zx.Span, resolved: bool = false };

pub fn infer(self: *Expression, item: anytype, span: zx.Span) zx.Error!Graph.Id {
    var target: Graph.Id = undefined;
    var value: Graph.Id = undefined;

    inline for (comptime Schedule.steps(.Index)) |step| {
        switch (step) {
            .Done => {},
            .InferTarget => target = try self.infer(item.target, null),
            .InferPosition => _ = try self.infer(item.index, try self.graph.scalar(.u64, span)),
            .RegisterIndex => {
                value = try self.graph.add(.unknown, span);

                const projection = Projection{
                    .target = target,
                    .value = value,
                    .position = try literalIndex(self, item.index),
                    .span = span,
                    .index_span = self.sourceSpan(item.index.span),
                };

                if (!try propagate(self.graph, projection)) try self.graph.pending.indexes.append(self.graph.pending.allocator, projection);
            },
            else => unreachable,
        }
    }

    return value;
}

pub fn propagate(graph: *Graph, projection: Projection) zx.Error!bool {
    if (!@import("rx_options").generated_graph) return seedPropagate(graph, projection);

    return @import("index/host.zig").immediate(graph, projection);
}

fn seedPropagate(graph: *Graph, projection: Projection) zx.Error!bool {
    const target = Target.Seed.read(graph, projection.target);
    const route = target.indexRoute(projection.position);

    const child: Target.Seed.Child = switch (route) {
        .List => target.member(0),
        .Tuple => target.member(@intCast(projection.position.?)),
        else => .{ .value = 0, .declared = false },
    };

    return applySeed(graph, projection, route, child);
}

fn applySeed(graph: *Graph, projection: Projection, route: anytype, child: Target.Seed.Child) zx.Error!bool {
    const value = switch (route) {
        .Wait => return false,
        .List, .Tuple => try Target.child(graph, child.value, child.declared, projection.span),
        .String => try graph.scalar(.u8, projection.span),
        .MissingLiteral => return graph.reporter.fail(.type_mismatch, projection.index_span, "tuple indexing requires an integer literal"),
        .OutOfBounds => return graph.reporter.fail(.type_mismatch, projection.index_span, "tuple index is out of bounds"),
        .Invalid => return graph.reporter.fail(.type_mismatch, projection.span, "indexing requires a list, tuple or string"),
    };

    try graph.unify(value, projection.value, projection.span);

    return true;
}

pub fn replay(graph: *Graph) zx.Error!void {
    const indexes = graph.pending.indexes.slice();
    const resolved = indexes.items(.resolved);

    if (!@import("rx_options").generated_graph) {
        for (resolved, 0..) |*done, index| {
            if (!done.*) done.* = try seedPropagate(graph, indexes.get(index));
        }

        return;
    }

    try @import("index/host.zig").run(graph, indexes);
}

pub fn isResult(graph: *const Graph, id: Graph.Id) bool {
    const indexes = graph.pending.indexes.slice();

    for (indexes.items(.value), indexes.items(.resolved)) |value, resolved| {
        if (!resolved and graph.root(value) == graph.root(id)) return true;
    }

    return false;
}

pub fn defaultLists(graph: *Graph) zx.Error!bool {
    const indexes = graph.pending.indexes.slice();
    const index = Projections.firstPending(graph, indexes.items(.target));
    const projection = indexes.get(index orelse return false);
    const value = try graph.payload(projection.target, .list, projection.span);

    try graph.unify(value, projection.value, projection.span);

    return true;
}

fn literalIndex(self: *Expression, source: anytype) zx.Error!?u64 {
    return switch (syntax.value(source)) {
        .number => |number| try @import("frontend").parseInteger(self.graph.allocator, number),
        else => null,
    };
}
