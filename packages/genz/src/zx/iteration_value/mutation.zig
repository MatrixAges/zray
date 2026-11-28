const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const publication = @import("../construction/publication.zig");
const entry = @import("generated_execute_iteration_mutation");

pub fn lower(context: *Context, id: zx.ir.ExprId) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(entry.Input);
    const self = context.lowering;
    const program: *const zx.ir.Program = &self.program;
    const expressions = zx.columns.borrow(std.meta.Child(@FieldType(Input, "expressions")), &program.expressions);

    return evaluation.invokeWith(self, entry, &.{
        .lower = @ptrCast(self),
        .writer = @ptrCast(self),
        .context = @ptrCast(context),
        .expressions = &expressions,
        .id = @backingInt(id),
    });
}
