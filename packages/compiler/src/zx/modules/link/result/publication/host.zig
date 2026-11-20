const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Model = @import("../../../artifact/model.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const Retained = @import("../../artifact/binding/abi.zig").Retained;
const program = @import("../host.zig");
const RegistrationView = @import("registration.zig").View;
const rule = @import("generated_artifact_program_publication");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(Input, "store_source"));
const Forward = std.meta.Child(@typeInfo(@FieldType(Input, "forward")).optional.child);
const Entry = std.meta.Child(@typeInfo(@FieldType(Input, "entry")).optional.child);
const Registration = std.meta.Child(@typeInfo(@FieldType(Input, "registration")).optional.child);

pub fn finish(allocator: std.mem.Allocator, module: *const Model.Module, function: ?Retained, tables: program.Tables, functions: *ir.FunctionStorage, mapping: []const ir.TypeId) Model.Error!ir.Program {
    const source_stores = zx.columns.columns(Store, module.stores);
    var surface: Surface(std.meta.Child(@FieldType(Input, "surface"))) = undefined;

    surface.init(module.exports, module.constant_exports, .{ .mapped = mapping });
    errdefer surface.release(allocator);

    var entry: Entry = undefined;

    if (function) |found| {
        entry = .{
            .ports = zx.columns.pointer(@FieldType(Entry, "ports"), found.ports),
            .body = zx.columns.pointer(@FieldType(Entry, "body"), found.body),
        };
    }

    const recursive = if (function) |found| found.recursive else null;
    var registration: RegistrationView(Registration) = undefined;
    var forward: Forward = undefined;

    if (recursive) |id| {
        const found = function.?;
        const body = found.body;
        const ports = found.ports;

        registration.init(&allocator, functions, &.{
            .file_name = found.file,
            .input_type = @as(ir.TypeId, @fromBackingInt(ports.input_type)),
            .output_type = @as(ir.TypeId, @fromBackingInt(ports.output_type)),
            .output_ownership = @as(@FieldType(ir.Function, "output_ownership"), @fromBackingInt(@intCast(@backingInt(ports.ownership)))),
            .store_mode = @as(ir.StoreMode, @fromBackingInt(@intCast(@backingInt(ports.store_mode)))),
            .body = Nodes.controlBody(if (body.root) |root| @fromBackingInt(root) else null, body.control),
        }, .{
            .symbols = zx.columns.pointer(*const ir.SymbolTable, body.symbols),
            .expressions = zx.columns.pointer(*const ir.ExpressionTable, body.expressions),
            .stores = if (found.stores) |stores| zx.columns.pointer(*const ir.StoreTable, stores) else null,
            .contracts = zx.columns.pointer(*const ir.ContractTable, body.contracts),
        });

        forward = .{
            .symbols = zx.columns.pointer(@FieldType(Forward, "symbols"), body.symbols),
            .input_type = ports.input_type,
            .output_type = ports.output_type,
            .function_id = id,
        };
    }

    const request: Input = .{
        .store_source = &source_stores,
        .surface = &surface.input,
        .path = module.path,
        .entry = if (function != null) &entry else null,
        .registration = if (recursive != null) &registration.input else null,
        .forward = if (recursive != null) &forward else null,
    };

    const outcome = rule.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const published = outcome orelse return error.InvalidModule;

    const linked_tables: program.Tables = .{
        .types = tables.types,
        .functions = functions.view(),
        .native_modules = tables.native_modules,
    };

    return program.fromPublication(published.path, published, linked_tables, surface.exports(), surface.constants());
}
