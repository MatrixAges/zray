const std = @import("std");
const ir = @import("zx").ir;
const generated = @import("generated_ownership");
const borrow = @import("../ir/canonical/borrow.zig");
const Input = std.meta.Child(generated.Input);
const Types = std.meta.Child(@FieldType(Input, "types"));
const Table = std.meta.Child(@FieldType(Types, "base"));
const Symbols = std.meta.Child(@FieldType(Input, "symbols"));
const Expressions = std.meta.Child(@FieldType(Input, "expressions"));
const Control = std.meta.Child(@FieldType(Input, "control"));
const Functions = std.meta.Child(@FieldType(Input, "functions"));
const FunctionColumns = std.meta.Child(@FieldType(Functions, "base"));

pub fn execute(allocator: std.mem.Allocator, program: ir.Program, suffix: ir.FunctionTable) !generated.Output {
    const base = ir.TypeTable.borrow(Table, program.types);
    const delta = ir.TypeTable.borrow(Table, .{});
    const types: Types = .{ .base = &base, .delta = &delta };
    const symbols = borrow.pointer(*const Symbols, &program.symbols);
    const expressions = borrow.pointer(*const Expressions, &program.expressions);
    const control = borrow.pointer(*const Control, program.body.control);
    const prefix_columns = functions(program.functions);
    const suffix_columns = if (suffix.count() != 0) functions(suffix) else null;
    const tables: Functions = .{ .base = &prefix_columns, .suffix = if (suffix_columns) |*columns| columns else null };

    const input: Input = .{
        .types = &types,
        .symbols = symbols,
        .expressions = expressions,
        .control = control,
        .body = if (program.body.root) |root| @backingInt(root) else null,
        .functions = &tables,
        .type_only = program.type_only,
    };

    return generated.executeIn(allocator, &input);
}

fn functions(table: ir.FunctionTable) FunctionColumns {
    return .{
        .ownership = borrow.slice(@FieldType(FunctionColumns, "ownership"), table.ownership),
        .stores = borrow.slice(@FieldType(FunctionColumns, "stores"), table.stores),
    };
}
