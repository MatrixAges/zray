const std = @import("std");
const zx = @import("zx");

pub fn valid(table: *const zx.ir.FunctionTable) bool {
    if (comptime !@import("parser_options").generated_parser) return table.validStructure();

    const rule = @import("generated_ir_function_structure");
    const Input = std.meta.Child(rule.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const functions = @import("canonical/functions/input.zig").view(Functions, table.*);

    const input: Input = .{
        .functions = &functions,
        .maximum_count = std.math.maxInt(u32),
        .verified = 0,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch false;
}
