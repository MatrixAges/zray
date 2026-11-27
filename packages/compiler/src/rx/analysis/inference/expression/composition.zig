const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("../types.zig");
const Expression = @import("../expression.zig");
const generated = @import("rx_options").generated_graph;
const Kind = enum { Template, Match };

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
        if (items.len == 0) return;

        const rule = @import("generated_rx_inference_operands");
        const Input = std.meta.Child(rule.Input);
        const context = items.context;
        var arena = std.heap.ArenaAllocator.init(self.graph.allocator);

        defer arena.deinit();

        var buffer: [512]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

        const input: Input = .{
            .tree = zx.columns.pointer(@FieldType(Input, "tree"), context.storage.expressions),
            .order = context.order.edges,
            .first = items.first,
            .end = items.first + items.len,
            .kind = if (kind == .Template) .Template else .Match,
        };

        const values = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        if (kind == .Template) {
            for (values) |value| _ = try self.infer(context.expression(value), null);
        } else {
            var index: usize = 0;

            while (index < values.len) : (index += 2) {
                _ = try self.infer(context.expression(values[index]), hints.subject);
                _ = try self.infer(context.expression(values[index + 1]), hints.result);
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
