const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;
const generated = @import("generated_inline_prepare");
const publishing = @import("generated_inline_publish");
const Input = std.meta.Child(generated.Input);
const PublishInput = std.meta.Child(publishing.Input);
const Program = std.meta.Child(@FieldType(Input, "program"));
const Functions = std.meta.Child(@FieldType(Program, "functions"));
const List = @import("../function_analysis/abi.zig").List;
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
        .scratch = @ptrCast(&temporary),
    };

    const planned = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (planned.entry == null and planned.functions.len == 0) return program;

    const Changes = List(@FieldType(PublishInput, "changes"));
    var changes = try Changes.init(temporary, planned.functions.len);

    for (planned.functions, changes.values) |item, *slot| {
        slot.* = bridgeRebuilt(Changes.Value, item);
    }

    var entry_value: ?Changes.Value = if (planned.entry) |item| bridgeRebuilt(Changes.Value, item) else null;
    const EntryField = @typeInfo(@FieldType(PublishInput, "entry")).optional.child;
    const PublishSource = std.meta.Child(@FieldType(PublishInput, "source"));

    const publish_source: PublishSource = .{
        .symbols = columns.slice(@FieldType(PublishSource, "symbols"), program.functions.symbols),
        .expressions = columns.slice(@FieldType(PublishSource, "expressions"), program.functions.expressions),
        .control = columns.slice(@FieldType(PublishSource, "control"), program.functions.control),
        .roots = columns.slice(@FieldType(PublishSource, "roots"), program.functions.roots),
    };

    const publish_input: PublishInput = .{
        .source = &publish_source,
        .changes = try changes.finish(temporary),
        .entry = if (entry_value) |*value| if (@typeInfo(EntryField) == .pointer) value else value.* else null,
    };

    const output = publishing.executeIn(allocator, &publish_input) catch |err| switch (err) {
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

fn bridgeRebuilt(comptime Target: type, source: anytype) Target {
    const src = unwrap(source);
    const SymbolsPtr = @typeInfo(@FieldType(Target, "symbols")).optional.child;

    return .{
        .unit = src.unit,
        .symbols = if (src.symbols) |symbols| bridgeField(SymbolsPtr, symbols) else null,
        .expressions = bridgeField(@FieldType(Target, "expressions"), src.expressions),
        .control = bridgeField(@FieldType(Target, "control"), src.control),
        .root = src.root,
    };
}

fn bridgeField(comptime Target: type, source: anytype) Target {
    if (@typeInfo(Target) == .pointer) return columns.pointer(Target, source);

    return columns.columns(Target, unwrap(source));
}
