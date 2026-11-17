const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;
const Artifact = @import("../artifact/model.zig");
const FunctionImport = @import("../function_import.zig");
const generated = @import("generated_semantic_cache_admit");
const Input = std.meta.Child(generated.Input);
const Header = std.meta.Child(@FieldType(Input, "header"));
const Function = std.meta.Child(@typeInfo(@FieldType(Input, "function_body")).optional.child);
const Bindings = std.meta.Child(@FieldType(Input, "imports"));
const Error = std.mem.Allocator.Error;

pub fn validate(allocator: std.mem.Allocator, module: *const Artifact.Module, expected: ?[]const u8) Error!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = scratch.allocator();
    const Tables = std.meta.Child(@FieldType(Header, "tables"));
    const signatures = columns.columns(std.meta.Child(@FieldType(Tables, "signatures")), module.functions);
    const natives = columns.columns(std.meta.Child(@FieldType(Tables, "modules")), module.native_modules);
    const stores = columns.columns(std.meta.Child(@FieldType(Tables, "stores")), module.stores);
    const tables: Tables = .{ .signatures = &signatures, .modules = &natives, .stores = &stores };
    const Type = std.meta.Child(@FieldType(Header, "types"));
    const types = ir.TypeTable.borrow(Type, module.types);
    const Constants = std.meta.Child(@typeInfo(@FieldType(Header, "constants")).optional.child);
    var constants: @import("../../analysis/constants/columns.zig").Pair(Constants) = undefined;
    const has_constants = module.constant_exports.len != 0 or module.constant_imports.len != 0;

    if (has_constants) constants.init(module.types, module.constant_exports, module.constant_imports);

    const header: Header = .{
        .tables = &tables,
        .types = &types,
        .scalar_count = std.enums.values(ir.Scalar).len,
        .maximum_count = std.math.maxInt(u32),
        .constants = if (has_constants) &constants.input else null,
    };

    const Body = std.meta.Child(@FieldType(Function, "body"));
    const Workspace = std.meta.Child(@FieldType(Function, "workspace"));
    var depths: zx.memory.U32Scratch = .{ .allocator = temporary };

    defer depths.deinit();

    const workspace = depths.borrow(Workspace, true);
    var body: Body = undefined;
    var function: Function = undefined;

    if (module.function) |*unit| {
        body = .{
            .stores = columns.pointer(@FieldType(Body, "stores"), &unit.stores),
            .symbols = columns.pointer(@FieldType(Body, "symbols"), &unit.symbols),
            .expressions = columns.pointer(@FieldType(Body, "expressions"), &unit.expressions),
            .control = columns.pointer(@FieldType(Body, "control"), unit.body.control),
            .root = if (unit.body.root) |root| @backingInt(root) else null,
        };

        function = .{
            .body = &body,
            .contracts = columns.pointer(@FieldType(Function, "contracts"), &unit.contracts),
            .max_offset = std.math.maxInt(usize),
            .workspace = &workspace,
        };
    }

    const imports = FunctionImport.Readable.borrowRows(module.function_imports);
    const members = FunctionImport.Readable.borrowRows(module.members);

    const input: Input = .{
        .path = module.path,
        .expected_path = expected,
        .header = &header,
        .imports = &imports.view(Bindings),
        .members = &members.view(Bindings),
        .function_body = if (module.function != null) &function else null,
    };

    return columns.invoke(generated.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
}
