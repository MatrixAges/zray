const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const frontend = @import("frontend");
const object_selection = frontend.object_selection;
pub const message = "RX values cannot contain calls or callbacks; move logic to ZX and use Call.fn or Call.module";

pub fn indexed(allocator: std.mem.Allocator, view: *const frontend.ExpressionInput.View, root: u64) std.mem.Allocator.Error!?zx.Diagnostic {
    const rule = @import("generated_rx_value_policy");
    const Input = std.meta.Child(rule.Input);
    const tree = view.storage.expressions;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var buffer: [64 * @sizeOf(u64)]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const input: Input = .{
        .source = view.source,
        .tree = zx.columns.pointer(@FieldType(Input, "tree"), tree),
        .order = &.{ .offsets = view.order.expressions, .edges = view.order.edges },
        .root = root,
    };

    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const detail: struct { @FieldType(zx.Diagnostic, "code"), []const u8 } = switch (result.issue) {
        .None => return null,
        .Unsupported => .{ .unsupported, message },
        .SelectionArity => .{ .type_mismatch, object_selection.arity_message },
        .SelectionArray => .{ .type_mismatch, object_selection.array_message },
        .SelectionLiteral => .{ .type_mismatch, object_selection.literal_message },
        .NestedConditional => .{ .style, @import("lint").nested_rx_conditional },
    };

    return .{ .code = detail[0], .message = detail[1], .span = zx.syntax.header.span(tree.nodes[@intCast(result.node)].span) };
}

pub fn validate(expression: anytype) ?zx.Diagnostic {
    switch (syntax.value(expression)) {
        .call => {
            if (!object_selection.matches(expression)) return .{ .code = .unsupported, .span = expression.span, .message = message };

            return object_selection.validate(expression) orelse validate(syntax.value(syntax.value(expression).call.callee).field.target);
        },
        .pipeline, .lambda, .state_block, .capture, .task, .await_task, .cancel_task => return .{ .code = .unsupported, .span = expression.span, .message = message },
        .field => |field| return validate(field.target),
        .index => |item| return validate(item.target) orelse validate(item.index),
        .unary => |unary| return validate(unary.operand),
        .binary => |binary| return validate(binary.left) orelse validate(binary.right),
        .conditional => |branch| return validate(branch.condition) orelse validate(branch.yes) orelse validate(branch.no),
        .object => |fields| for (0..fields.len) |index| {
            const field = syntax.item(fields, index);

            if (validate(field.value)) |issue| return issue;
        },
        .list => |items| for (0..items.len) |index| {
            const item = syntax.item(items, index);

            if (validate(item)) |issue| return issue;
        },
        .template => |parts| for (0..parts.len) |index| {
            const part = syntax.item(parts, index);

            if (part == .expression) if (validate(part.expression)) |issue| return issue;
        },
        .match_expr => |selection| {
            if (selection.subject) |subject| if (validate(subject)) |issue| return issue;

            for (0..selection.arms.len) |index| {
                const arm = syntax.item(selection.arms, index);

                if (validate(arm.condition) orelse validate(arm.result)) |issue| return issue;
            }

            return validate(selection.fallback);
        },
        .identifier, .number, .boolean, .string, .null_value => {},
    }

    return null;
}
