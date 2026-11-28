const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const publication = @import("../construction/publication.zig");

pub fn lower(self: *Lower, statements: ir.Block, index: usize) Lower.Error!node.Block {
    if (!@import("genz_options").generated_analysis) {
        const begin = (try @import("begin_seed.zig").statement(self, statements, index)) orelse return .{};

        return self.builder.statements(&.{begin});
    }

    const entry = @import("generated_store_begin");
    const Input = std.meta.Child(entry.Input);
    const Control = std.meta.Child(@FieldType(Input, "control"));
    const Values = std.meta.Child(@FieldType(Input, "values"));

    const control: Control = .{
        .statement_kinds = zx.columns.slice(@FieldType(Control, "statement_kinds"), statements.control.statement_kinds),
        .statement_payloads = statements.control.statement_payloads,
        .evaluations = statements.control.evaluations,
        .constant_values = statements.control.constant_values,
    };

    const values: Values = .{
        .kinds = zx.columns.slice(@FieldType(Values, "kinds"), self.program.expressions.kinds),
        .payloads = self.program.expressions.payloads,
        .stores = self.program.expressions.stores,
        .call_functions = self.program.expressions.call_functions,
        .call_store_first = self.program.expressions.call_store_first,
        .call_store_count = self.program.expressions.call_store_count,
        .call_stores = self.program.expressions.call_stores,
    };

    const input: Input = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .control = &control,
        .values = &values,
        .function_modes = zx.columns.slice(@FieldType(Input, "function_modes"), self.program.functions.store_modes),
        .first = statements.first,
        .count = statements.len,
        .index = index,
    };

    return publication.executeSpan(self, entry, &input);
}
