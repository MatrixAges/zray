const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const generated = @import("generated_abi_definitions");

pub fn build(self: *Lower, declarations: ?*@import("../../node/declarations.zig").Output, exported: bool) Lower.Error!bool {
    const Input = std.meta.Child(generated.Input);
    const Output = std.meta.Child(@FieldType(std.meta.Child(generated.Output), "types"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const input: Input = .{
        .types = &types,
        .names = self.type_names,
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .exported = exported,
    };

    const result = @import("zx").columns.invoke(generated.executeValue, scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const output = result.types;

    if (!output.valid) return error.OutOfMemory;

    try @import("import.zig").append(self, declarations, Output, output, result.fields, if (self.type_names != null) .borrow_text else .copy);

    @memcpy(@as([]u32, @ptrCast(self.types)), output.values);
    @memcpy(@as([]u32, @ptrCast(self.layouts)), output.layouts);

    return output.has_lists;
}
