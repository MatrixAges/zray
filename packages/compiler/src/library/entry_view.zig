const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;
const generated = @import("parser_options").generated_parser;
const entry = if (generated) @import("generated_library_entry_view") else void;
const empty_stores: ir.StoreTable = .{};

pub fn apply(program: *ir.Program, function: ?ir.FunctionId, initializer: bool) void {
    if (comptime !generated) {
        const id = function orelse return;
        const body = program.functions.at(@backingInt(id));

        program.type_only = false;
        program.input_type = body.input_type;
        program.output_type = body.output_type;
        program.output_ownership = body.output_ownership;
        program.symbols = body.symbols;
        program.expressions = body.expressions;
        program.body = body.body;
        program.contracts = body.contracts;

        if (initializer) {
            program.stores = .{};
        } else {
            program.file_name = body.file_name;
            program.store_mode = body.store_mode;
            program.stores = body.stores;
        }

        return;
    }

    const Input = std.meta.Child(entry.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const Initializer = std.meta.Child(@typeInfo(@FieldType(Input, "initializer")).optional.child);
    const functions = &program.functions;

    const source: Functions = .{
        .files = functions.files,
        .input_types = functions.input_types,
        .output_types = functions.output_types,
        .ownership = columns.slice(@FieldType(Functions, "ownership"), functions.ownership),
        .store_modes = columns.slice(@FieldType(Functions, "store_modes"), functions.store_modes),
        .symbols = columns.slice(@FieldType(Functions, "symbols"), functions.symbols),
        .expressions = columns.slice(@FieldType(Functions, "expressions"), functions.expressions),
        .control = columns.slice(@FieldType(Functions, "control"), functions.control),
        .roots = functions.roots,
        .contracts = columns.slice(@FieldType(Functions, "contracts"), functions.contracts),
        .stores = columns.slice(@FieldType(Functions, "stores"), functions.stores),
    };

    const init: Initializer = .{
        .file = program.file_name,
        .store_mode = @fromBackingInt(@backingInt(program.store_mode)),
        .empty_stores = columns.pointer(@FieldType(Initializer, "empty_stores"), &empty_stores),
    };

    const input: Input = .{
        .functions = &source,
        .function_id = if (function) |id| @backingInt(id) else null,
        .initializer = if (initializer) &init else null,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const body = (columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable) orelse return;

    program.file_name = body.file;
    program.type_only = false;
    program.input_type = @fromBackingInt(body.input_type);
    program.output_type = @fromBackingInt(body.output_type);
    program.output_ownership = @fromBackingInt(@backingInt(body.ownership));
    program.store_mode = @fromBackingInt(@backingInt(body.store_mode));
    program.symbols = columns.borrow(ir.SymbolTable, body.symbols);
    program.expressions = columns.borrow(ir.ExpressionTable, body.expressions);
    program.contracts = columns.borrow(ir.ContractTable, body.contracts);
    program.stores = columns.borrow(ir.StoreTable, body.stores);

    program.body = .{
        .control = columns.pointer(*const ir.ControlTable, body.control),
        .root = if (body.root) |id| @fromBackingInt(id) else null,
    };
}
