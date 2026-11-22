const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");

pub fn fill(self: *const Lower, values: ir.Block, target: []u8) Lower.Error!void {
    if (values.len == 0) return;

    const rule = @import("generated_statement_block_plan");
    const Input = std.meta.Child(rule.Input);
    const Control = std.meta.Child(@FieldType(Input, "control"));
    const Values = std.meta.Child(@FieldType(Input, "values"));

    const control: Control = .{
        .statement_kinds = zx.columns.slice(@FieldType(Control, "statement_kinds"), values.control.statement_kinds),
        .statement_payloads = values.control.statement_payloads,
        .evaluations = values.control.evaluations,
        .constant_values = values.control.constant_values,
        .results = values.control.results,
    };

    const expressions: Values = .{
        .kinds = zx.columns.slice(@FieldType(Values, "kinds"), self.program.expressions.kinds),
        .types = self.program.expressions.types,
        .type_kinds = self.program.types.kinds,
    };

    const input: Input = .{
        .control = &control,
        .values = &expressions,
        .first = values.first,
        .count = values.len,
        .mode = @fromBackingInt(@backingInt(self.program.store_mode)),
        .store_count = self.program.stores.count(),
        .target = @ptrCast(&target),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}
