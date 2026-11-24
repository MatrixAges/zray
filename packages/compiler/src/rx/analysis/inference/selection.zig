const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const selection = @import("frontend").object_selection;
const Graph = @import("types.zig");
const ObjectReadiness = @import("object_closure/seed.zig");
const Expression = @import("expression.zig");

pub const Selection = struct { source: Graph.Id, result: Graph.Id, keys: []const []const u8, omit: bool, span: zx.Span };
pub const incomplete_source = "object selection requires a complete source type; declare Args or Input";

pub fn infer(self: *Expression, expression: anytype, call: anytype, span: zx.Span) zx.Error!Graph.Id {
    const keys = try readKeys(self, expression, span);
    const field = syntax.value(call.callee).field;
    const source = try self.infer(field.target, null);
    const result = try self.graph.add(.{ .object = .{} }, span);

    try self.graph.pending.selections.append(self.graph.pending.allocator, .{
        .source = source,
        .result = result,
        .keys = keys,
        .omit = std.mem.eql(u8, field.name.text, "omit"),
        .span = span,
    });

    return result;
}

fn readKeys(self: *Expression, expression: anytype, span: zx.Span) zx.Error![]const []const u8 {
    if (!selection.matches(expression)) return self.graph.reporter.fail(.unsupported, span, @import("../value_rules.zig").message);

    var reporter: zx.Reporter = .{};

    return selection.keys(self.graph.pending.allocator, expression, &reporter) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        const issue = reporter.diagnostic.?;

        return self.graph.reporter.fail(issue.code, self.sourceSpan(issue.span), issue.message);
    };
}

pub fn replaySeed(graph: *Graph, final: bool) zx.Error!void {
    const pending = graph.pending.selections.slice();

    for (0..pending.len) |index| {
        const value = pending.get(index);

        if (ObjectReadiness.prove(graph, value.source, .selection, 0)) {
            try @import("selection/seed.zig").apply(graph, value, final);
        } else if (final) return graph.reporter.fail(.type_mismatch, value.span, incomplete_source);
    }
}
