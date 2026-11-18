const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Model = @import("../../../artifact/model.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const program = @import("../host.zig");
const RegistrationView = @import("registration.zig").View;
const rule = @import("generated_artifact_program_publication");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(Input, "store_source"));
const Forward = std.meta.Child(@typeInfo(@FieldType(Input, "forward")).optional.child);
const Symbols = std.meta.Child(@FieldType(Forward, "symbols"));
const Entry = std.meta.Child(@typeInfo(@FieldType(Input, "entry")).optional.child);
const Body = std.meta.Child(@FieldType(Entry, "body"));
const Ports = std.meta.Child(@FieldType(Entry, "ports"));
const Expressions = std.meta.Child(@FieldType(Body, "expressions"));
const Contracts = std.meta.Child(@FieldType(Body, "contracts"));
const Registration = std.meta.Child(@typeInfo(@FieldType(Input, "registration")).optional.child);

pub fn finish(allocator: std.mem.Allocator, module: *const Model.Module, function: ?*const Nodes.FunctionEntry, tables: program.Tables, functions: *ir.FunctionStorage, mapping: []const ir.TypeId) Model.Error!ir.Program {
    const source_stores = zx.columns.columns(Store, module.stores);
    var surface: Surface(std.meta.Child(@FieldType(Input, "surface"))) = undefined;

    surface.init(module.exports, module.constant_exports, .{ .mapped = mapping });
    errdefer surface.release(allocator);

    var entry: Entry = undefined;
    var ports: Ports = undefined;
    var body: Body = undefined;
    var symbols: Symbols = undefined;
    var expressions: Expressions = undefined;
    var contracts: Contracts = undefined;

    if (function) |found| {
        const value = &found.body;

        symbols = zx.columns.columns(Symbols, value.symbols);
        expressions = zx.columns.columns(Expressions, value.expressions);
        contracts = zx.columns.columns(Contracts, value.contracts);

        ports = .{
            .input_type = @backingInt(value.input_type),
            .output_type = @backingInt(value.output_type),
            .ownership = @fromBackingInt(@intCast(@backingInt(value.output_ownership))),
            .store_mode = @fromBackingInt(@intCast(@backingInt(value.store_mode))),
        };

        body = .{
            .symbols = zx.columns.pointer(@FieldType(Body, "symbols"), @as(*const Symbols, &symbols)),
            .expressions = &expressions,
            .contracts = &contracts,
            .control = if (value.body.root != null) zx.columns.pointer(@typeInfo(@FieldType(Body, "control")).optional.child, value.body.control) else null,
            .root = if (value.body.root) |id| @backingInt(id) else null,
        };

        entry = .{ .ports = &ports, .body = &body };
    }

    const recursive = if (function) |found| found.recursive else null;
    var registration: RegistrationView(Registration) = undefined;
    var forward: Forward = undefined;

    if (recursive) |id| {
        const found = function.?;

        registration.init(&allocator, functions, &found.body, found.descriptors.?);

        forward = .{
            .symbols = &symbols,
            .input_type = ports.input_type,
            .output_type = ports.output_type,
            .function_id = @backingInt(id),
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
