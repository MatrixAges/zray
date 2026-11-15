const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const selection = @import("frontend").object_selection;
const Graph = @import("types.zig");
const ObjectClosure = @import("object_closure.zig");
const Expression = @import("expression.zig");
const Schedule = @import("expression/schedule.zig");

pub const Selection = struct { source: Graph.Id, result: Graph.Id, keys: []const []const u8, omit: bool, span: zx.Span };

const incomplete_source = "object selection requires a complete source type; declare Args or Input";

pub fn infer(self: *Expression, expression: anytype) zx.Error!Graph.Id {
    var keys: []const []const u8 = undefined;
    var source: Graph.Id = undefined;
    var result: Graph.Id = undefined;
    var omit: bool = undefined;

    inline for (comptime Schedule.steps(.Selection)) |step| {
        switch (step) {
            .Done => {},
            .ReadKeys => keys = try readKeys(self, expression),
            .InferReceiver => {
                const field = syntax.value(syntax.value(expression).call.callee).field;

                source = try self.infer(field.target, null);
                omit = std.mem.eql(u8, field.name.text, "omit");
            },
            .RegisterSelection => {
                const span = self.sourceSpan(expression.span);

                result = try self.graph.add(.{ .object = .{} }, span);

                try self.graph.pending.selections.append(self.graph.pending.allocator, .{
                    .source = source,
                    .result = result,
                    .keys = keys,
                    .omit = omit,
                    .span = span,
                });
            },
            else => unreachable,
        }
    }

    return result;
}

fn readKeys(self: *Expression, expression: anytype) zx.Error![]const []const u8 {
    if (!selection.matches(expression)) return self.graph.reporter.fail(.unsupported, self.sourceSpan(expression.span), @import("../value_rules.zig").message);

    var reporter: zx.Reporter = .{};

    return selection.keys(self.graph.pending.allocator, expression, &reporter) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        const issue = reporter.diagnostic.?;

        return self.graph.reporter.fail(issue.code, self.sourceSpan(issue.span), issue.message);
    };
}

pub fn replay(graph: *Graph, closure: *ObjectClosure, final: bool) zx.Error!void {
    const pending = graph.pending.selections.slice();

    if (comptime !@import("rx_options").generated_graph) {
        for (0..pending.len) |index| {
            const value = pending.get(index);

            if (try closure.prove(graph, value.source, .selection)) {
                try @import("selection/seed.zig").apply(graph, value, final);
            } else if (final) return graph.reporter.fail(.type_mismatch, value.span, incomplete_source);
        }

        return;
    }

    const sources = pending.items(.source);
    var start: usize = 0;

    while (try closure.nextSelection(graph, sources, start, final)) |next| {
        const value = pending.get(next.row);

        if (!next.ready) return graph.reporter.fail(.type_mismatch, value.span, incomplete_source);
        try @import("selection/project.zig").apply(graph, value, next.root, final);

        start = next.row + 1;
    }
}
