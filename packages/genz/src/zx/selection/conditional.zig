const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Operation = @FieldType(@FieldType(zx.ir.ExpressionRow, "value"), "conditional");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, value: Operation) Lower.Error!node.ExpressionId {
    if (!generated) return construct(self, try self.expr(value.condition), try self.expr(value.yes), try self.expr(value.no));

    return evaluate(self, value, false);
}

pub fn lowerValue(self: *Lower, value: Operation) Lower.Error!node.ExpressionId {
    return evaluate(self, value, true);
}

fn evaluate(self: *Lower, value: Operation, comptime layout: bool) Lower.Error!node.ExpressionId {
    const form = if (layout) .ValueConditional else .Conditional;
    const operands = try @import("../expressions/operands.zig").evaluate(self, form, &.{ value.condition, value.yes, value.no });

    return construct(self, operands[0], operands[1], operands[2]);
}

pub fn construct(self: *Lower, condition: node.ExpressionId, yes: node.ExpressionId, no: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!generated) return self.builder.expression(.{ .conditional = .{ .condition = condition, .yes = yes, .no = no } });

    const entry = @import("generated_conditional_emit");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);
    const input: Input = .{ .condition = @backingInt(condition), .yes = @backingInt(yes), .no = @backingInt(no) };
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = try zx.columns.invoke(entry.executeValue, memory.allocator(), @as(*const Input, &input));
    const emitted = zx.columns.view(Output, output);
    const root = self.builder.nodes.expressions.tags.items.len;

    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &emitted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    return @fromBackingInt(@intCast(root));
}
