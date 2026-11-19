const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("terms.zig");
const scalar = @import("scalar.zig");
const Value = terms.Value;
const Evaluation = terms.Evaluation;
const Self = @This();
const Graph = @import("graph.zig");

allocator: std.mem.Allocator,
scratch: *zx.Arena,
program: ir.Program,
environment: []?Value,
reporter: *zx.Reporter,
graph: *Graph,
cache: std.AutoHashMapUnmanaged(ir.ExprId, Evaluation) = .empty,
depth: usize = 0,
call_depth: usize = 0,
pub fn evaluate(self: *Self, id: ir.ExprId) zx.Error!Evaluation {
    if (self.cache.get(id)) |result| return result;

    const expression = self.program.expression(id);

    try self.graph.step(expression.span);

    const result = try self.retain(expression, try self.evaluateRaw(id, expression));

    try self.cache.put(self.scratch.allocator(), id, result);

    return result;
}

fn retain(self: *Self, expression: ir.ExpressionRow, result: Evaluation) zx.Error!Evaluation {
    return .{
        .value = try self.graph.retain(self.program, expression.type_id, result.value, expression.span),
        .safe = try self.boolean(result.safe, expression.span),
    };
}

fn boolean(self: *Self, value: []const u8, span: zx.Span) zx.Error![]const u8 {
    return self.graph.bind(value, 0, .{ .file_name = self.program.file_name, .span = span });
}

fn evaluateRaw(self: *Self, id: ir.ExprId, expression: ir.ExpressionRow) zx.Error!Evaluation {
    if (self.depth >= 256) return self.reporter.fail(.unsupported, expression.span, "verification expression depth exceeds 256");

    self.depth += 1;
    defer self.depth -= 1;

    switch (expression.value) {
        .reference => |symbol| return .{ .value = self.environment[@backingInt(symbol)] orelse return self.reporter.fail(.contract, expression.span, "verification encountered an unbound symbol") },
        .integer, .negative_integer => |number| {
            const target = terms.integer(self.program.typeOf(expression.type_id)).?;
            const value = try terms.literal(self.allocator, number, target.width, expression.value == .negative_integer);

            return .{ .value = .{ .scalar = value } };
        },
        .enum_value => |member| return .{ .value = .{ .scalar = try terms.literal(self.allocator, member, terms.enumWidth(self.program.typeOf(expression.type_id)), false) } },
        .boolean => |value| return .{ .value = .{ .scalar = if (value) "true" else "false" } },
        .unit => return .{ .value = .{ .fields = &.{} } },
        .field, .tuple_field => |field| {
            const result = try self.evaluate(field.target);

            return .{ .value = result.value.fields[field.index], .safe = result.safe };
        },
        .unary => |operation| {
            const operand = try self.evaluate(operation.operand);
            const target = self.program.typeOf(expression.type_id);
            const value = try scalar.unary(self.allocator, operation.operator == .not, target, operand);

            return value orelse self.unsupported(expression);
        },
        .binary => |operation| {
            const left = try self.evaluate(operation.left);
            const right = try self.evaluate(operation.right);
            const target = self.program.typeOf(self.program.expression(operation.left).type_id);
            const value = try scalar.binary(self.allocator, &self.program.expressions, id, operation.operator, target, left, right);

            return value orelse self.unsupported(expression);
        },
        .call => return @import("calls.zig").evaluate(self, expression),
        .conditional => |choice| {
            const condition = try self.evaluate(choice.condition);
            const yes = try self.evaluate(choice.yes);
            const no = try self.evaluate(choice.no);

            return .{
                .value = try self.graph.select(self.program, expression.type_id, condition.value.scalar, yes.value, no.value, expression.span),
                .safe = try terms.guarded(self.allocator, condition.value.scalar, condition.safe, yes.safe, no.safe),
            };
        },
        .match_expr => |selection| {
            const subject = if (selection.subject) |subject_id| try self.evaluate(subject_id) else null;
            var result = try self.evaluate(selection.fallback);
            var index = selection.arms.len;

            while (index > 0) {
                index -= 1;
                const arm = selection.arms.at(index);
                const condition = try self.evaluate(arm.condition);
                const yes = try self.evaluate(arm.result);
                const selected = if (subject) |value| try terms.connect(self.allocator, .Equal, value.value.scalar, condition.value.scalar) else condition.value.scalar;

                result = try self.retain(expression, .{
                    .value = try self.graph.select(self.program, expression.type_id, selected, yes.value, result.value, expression.span),
                    .safe = try terms.guarded(self.allocator, selected, condition.safe, yes.safe, result.safe),
                });
            }

            if (subject) |value| result.safe = try terms.connect(self.allocator, .And, value.safe, result.safe);

            return result;
        },
        .tuple => |items| {
            const fields = try self.allocator.alloc(Value, items.len);
            var safe: []const u8 = "true";

            for (items, fields) |item, *field| {
                const value = try self.evaluate(item);

                field.* = value.value;
                safe = try self.boolean(try terms.connect(self.allocator, .And, safe, value.safe), expression.span);
            }

            return .{ .value = .{ .fields = fields }, .safe = safe };
        },
        .object => |object| {
            const fields = try self.allocator.alloc(Value, object.fields.len);
            var safe: []const u8 = "true";

            for (object.evaluation) |item| {
                const value = try self.evaluate(item);

                safe = try self.boolean(try terms.connect(self.allocator, .And, safe, value.safe), expression.span);
            }

            for (0..object.fields.len) |record_index| {
                const field = object.fields.at(record_index);
                const value = try self.evaluate(field.value);

                fields[field.index] = value.value;
                safe = try self.boolean(try terms.connect(self.allocator, .And, safe, value.safe), expression.span);
            }

            return .{ .value = .{ .fields = fields }, .safe = safe };
        },
        else => return self.unsupported(expression),
    }
}

fn unsupported(self: *Self, expression: ir.ExpressionRow) zx.Error {
    return self.reporter.fail(.unsupported, expression.span, "formal verification does not yet model this expression");
}
