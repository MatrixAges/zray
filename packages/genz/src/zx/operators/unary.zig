const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const Operator = std.meta.Child(@FieldType(ir.ExpressionTable, "unary_operators"));

pub fn emit(self: *Lower, operator: Operator, operand: node.ExpressionId) Lower.Error!node.ExpressionId {
    const generated = @import("generated_unary_emit");
    const Input = std.meta.Child(generated.Input);
    const Output = std.meta.Child(generated.Output);

    comptime view.compatible(Operator, @FieldType(Input, "operator"));

    const input: Input = .{ .operator = @fromBackingInt(@intCast(@backingInt(operator))), .operand = @backingInt(operand) };
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = try zx.columns.invoke(generated.executeValue, memory.allocator(), @as(*const Input, &input));
    const emitted = zx.columns.view(Output, output);
    const root = self.builder.nodes.expressions.tags.items.len;

    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &emitted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    return @fromBackingInt(@intCast(root));
}
