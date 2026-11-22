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

    const input: Input = .{
        .program = &view,
        .allocator = @ptrCast(&temporary),
    };

    const output = generated.execute(&scratch, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    var result = program;

    if (output.entry) |entry| {
        const rebuilt = try own(allocator, unwrap(entry));

        result.symbols = rebuilt.symbols orelse program.symbols;
        result.expressions = rebuilt.expressions;
        result.body = rebuilt.body;
    }

    if (output.functions.len != 0) result.functions = try publishFunctions(allocator, program.functions, output.functions);

    return result;
}

const Owned = struct { symbols: ?ir.SymbolTable, expressions: ir.ExpressionTable, body: ir.ControlBody };

fn publishFunctions(allocator: std.mem.Allocator, source: ir.FunctionTable, changes: anytype) std.mem.Allocator.Error!ir.FunctionTable {
    const symbols = try allocator.dupe(*const ir.SymbolTable, source.symbols);
    const expressions = try allocator.dupe(*const ir.ExpressionTable, source.expressions);
    const control = try allocator.dupe(*const ir.ControlTable, source.control);
    const roots = try allocator.dupe(?u32, source.roots);
    const owned = try allocator.alloc(Owned, changes.len);

    for (changes, owned) |change, *row| {
        const rebuilt = unwrap(change);
        const index: usize = @intCast(rebuilt.unit);

        row.* = try own(allocator, rebuilt);

        if (row.symbols) |*replacement| symbols[index] = replacement;

        expressions[index] = &row.expressions;
        control[index] = row.body.control;
        roots[index] = rebuilt.root;
    }

    var result = source;

    result.symbols = symbols;
    result.expressions = expressions;
    result.control = control;
    result.roots = roots;

    return result;
}

fn own(allocator: std.mem.Allocator, rebuilt: anytype) std.mem.Allocator.Error!Owned {
    const control = try allocator.create(ir.ControlTable);

    control.* = try columns.own(allocator, columns.columns(ir.ControlTable, rebuilt.control.*), .{});

    return .{
        .symbols = if (rebuilt.symbols) |symbols| try columns.own(allocator, columns.columns(ir.SymbolTable, symbols.*), .{}) else null,
        .expressions = try columns.own(allocator, columns.columns(ir.ExpressionTable, rebuilt.expressions.*), .{}),
        .body = .{ .control = control, .root = @fromBackingInt(rebuilt.root) },
    };
}
