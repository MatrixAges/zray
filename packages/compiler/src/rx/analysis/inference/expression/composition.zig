const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("../types.zig");
const Expression = @import("../expression.zig");
const generated = @import("rx_options").generated_graph;
const Kind = enum { Template, Match };
const batch_size = 16;

pub fn template(self: *Expression, parts: anytype, span: zx.Span) zx.Error!Graph.Id {
    try visit(.Template, self, parts, null);

    return self.graph.scalar(.string, span);
}

pub fn matching(self: *Expression, selection: anytype, expected: ?Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    const result = expected orelse try self.graph.add(.unknown, span);
    const subject = if (selection.subject) |item| try self.infer(item, null) else try self.graph.scalar(.bool, span);

    try visit(.Match, self, selection.arms, .{ .subject = subject, .result = result });

    _ = try self.infer(selection.fallback, result);

    return result;
}

const Hints = struct { subject: Graph.Id, result: Graph.Id };

fn visit(comptime kind: Kind, self: *Expression, items: anytype, hints: if (kind == .Match) Hints else @TypeOf(null)) zx.Error!void {
    if (comptime generated and @typeInfo(@TypeOf(items)) == .@"struct") {
        const rule = @import("generated_rx_inference_operands");
        const Input = std.meta.Child(rule.Input);
        const context = items.context;
        const width = if (kind == .Template) 1 else 2;
        var values: [batch_size * width]u64 = undefined;
        var target: []u64 = &values;
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        var position = items.first;
        const end = position + items.len;

        while (position < end) {
            const input: Input = .{
                .tree = zx.columns.pointer(@FieldType(Input, "tree"), context.storage.expressions),
                .order = context.order.edges,
                .first = position,
                .end = end,
                .capacity = batch_size,
                .kind = if (kind == .Template) .Template else .Match,
                .target = @ptrCast(&target),
            };

            const page = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

            position = @intCast(page.next);

            for (0..@intCast(page.written)) |index| {
                const left = context.expression(values[index * width]);

                if (kind == .Template) {
                    _ = try self.infer(left, null);
                } else {
                    _ = try self.infer(left, hints.subject);
                    _ = try self.infer(context.expression(values[index * width + 1]), hints.result);
                }
            }
        }

        return;
    }

    for (0..items.len) |index| {
        const item = syntax.item(items, index);

        if (kind == .Template) {
            if (item == .expression) _ = try self.infer(item.expression, null);
        } else {
            _ = try self.infer(item.condition, hints.subject);
            _ = try self.infer(item.result, hints.result);
        }
    }
}
