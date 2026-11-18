const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const Nodes = @import("../../../artifact/nodes.zig");
const remap = @import("../../../artifact/nodes/remap.zig");
const result = @import("../../../link/result/host.zig");
const registration = @import("../../../link/result/publication/registration.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const generated = @import("generated_semantic_restore_publication");
const Input = std.meta.Child(generated.Input);
const Body = std.meta.Child(@typeInfo(@FieldType(Input, "body")).optional.child);
const Control = @typeInfo(@FieldType(Input, "control")).optional.child;
const Stores = std.meta.Child(@FieldType(Input, "stores"));
const Attributes = std.meta.Child(@typeInfo(@FieldType(Input, "attributes")).optional.child);
const Restored = @import("../../restore.zig").Restored;

pub const Target = struct {
    allocator: std.mem.Allocator,
    functions: *ir.FunctionStorage,
    tables: result.Tables,
    path: []const u8,
};

pub fn materialize(nodes: *Nodes, module: *const Artifact.Module, target: Target, candidate: ?ir.FunctionId, structure: Nodes.Structure) Artifact.Error!Restored {
    const source = if (module.function) |*value| value else null;
    var view: remap.FunctionView(Body) = undefined;
    var control_source: ?Control = null;
    var attributes: Attributes = undefined;

    if (source) |value| {
        if (structure == .unchecked and !remap.validFunctionColumns(value)) return error.InvalidModule;

        view.init(nodes, value, candidate);

        if (value.body.root != null) control_source = zx.columns.pointer(Control, value.body.control);

        attributes = .{
            .ownership = @fromBackingInt(@intCast(@backingInt(value.output_ownership))),
            .store_mode = @fromBackingInt(@intCast(@backingInt(value.store_mode))),
            .root = if (value.body.root) |id| @backingInt(id) else null,
        };
    }

    const stores = zx.columns.columns(Stores, module.stores);
    var surface: Surface(std.meta.Child(@FieldType(Input, "surface"))) = undefined;

    surface.init(module.exports, module.constant_exports, nodes.types);
    errdefer surface.release(nodes.allocator);

    const input: Input = .{
        .body = if (source != null) &view.input else null,
        .control = control_source,
        .attributes = if (source != null) &attributes else null,
        .stores = &stores,
        .reuse_store_types = if (source) |value| sameColumn(module.stores.types, value.stores.types) else false,
        .surface = &surface.input,
    };

    const prepared = zx.columns.invoke(generated.executeValue, nodes.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const plan = prepared orelse return error.InvalidModule;
    var program = result.fromPublication(target.path, plan, target.tables, surface.exports(), surface.constants());

    if (plan.recursive) |id| {
        const body = plan.body.?;

        try registration.append(target.allocator, target.functions, &program, .{
            .symbols = zx.columns.pointer(*const ir.SymbolTable, body.symbols),
            .expressions = zx.columns.pointer(*const ir.ExpressionTable, body.expressions),
            .stores = zx.columns.pointer(*const ir.StoreTable, plan.stores),
            .contracts = zx.columns.pointer(*const ir.ContractTable, body.contracts),
        });

        program.functions = target.functions.view();

        return .{ .program = program, .recursive = @fromBackingInt(id) };
    }

    return .{ .program = program, .recursive = null };
}

fn sameColumn(left: []const u32, right: []const u32) bool {
    return left.len == right.len and (left.len == 0 or left.ptr == right.ptr);
}
