const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;
const generated = @import("generated_inline_prepare");
const Input = std.meta.Child(generated.Input);
const Program = std.meta.Child(@FieldType(Input, "program"));
const Functions = std.meta.Child(@FieldType(Program, "functions"));
const unwrap = @import("../function_analysis/abi.zig").unwrap;

/// The returned program borrows unchanged storage from the input. The output allocator owns replacements.
pub fn prepare(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program) std.mem.Allocator.Error!ir.Program {
    if (program.functions.count() == 0) return program;

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Program, "types")), program.types);
    var functions: Functions = undefined;

    inline for (@typeInfo(Functions).@"struct".field_names) |name| {
        @field(functions, name) = columns.slice(@FieldType(Functions, name), @field(program.functions, name));
    }

    const view = Program{
        .types = &types,
        .symbols = columns.pointer(@FieldType(Program, "symbols"), &program.symbols),
        .functions = &functions,
        .stores = columns.pointer(@FieldType(Program, "stores"), &program.stores),
        .expressions = columns.pointer(@FieldType(Program, "expressions"), &program.expressions),
        .contracts = columns.pointer(@FieldType(Program, "contracts"), &program.contracts),
        .control = columns.pointer(@FieldType(Program, "control"), program.body.control),
        .root = if (program.body.root) |root| @backingInt(root) else null,
        .output_type = @backingInt(program.output_type),
    };

    const Allocators = std.meta.Child(@FieldType(Input, "allocators"));
    var scope = zx.memory.ArenaScope{ .active = temporary };

    const allocators: Allocators = .{
        .scope = @ptrCast(&scope),
        .scratch = @ptrCast(&temporary),
        .owned = @ptrCast(&allocator),
    };

    const input: Input = .{
        .program = &view,
        .allocators = &allocators,
    };

    const output = generated.executeIn(scope.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    var result = program;

    if (output.entry) |body| {
        const entry = unwrap(body);

        if (entry.symbols) |symbols| result.symbols = columns.columns(ir.SymbolTable, unwrap(symbols));

        result.expressions = columns.columns(ir.ExpressionTable, unwrap(entry.expressions));
        result.body = .{ .control = columns.pointer(*const ir.ControlTable, entry.control), .root = @fromBackingInt(entry.root) };
    }

    if (output.functions) |published| {
        const body_columns = unwrap(published);

        inline for (@typeInfo(@TypeOf(body_columns)).@"struct".field_names) |name| {
            @field(result.functions, name) = columns.slice(@FieldType(ir.FunctionTable, name), @field(body_columns, name));
        }
    }

    return result;
}
