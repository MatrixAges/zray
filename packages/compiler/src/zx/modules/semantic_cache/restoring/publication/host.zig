const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const Nodes = @import("../../../artifact/nodes.zig");
const remap = @import("../../../artifact/nodes/remap.zig");
const result = @import("../../../link/result/host.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const generated = @import("generated_semantic_restore_publication");
const Input = std.meta.Child(generated.Input);
const Body = std.meta.Child(@typeInfo(@FieldType(Input, "body")).optional.child);
const Control = @typeInfo(@FieldType(Input, "control")).optional.child;
const Stores = std.meta.Child(@FieldType(Input, "stores"));
const Restored = @import("../../restore.zig").Restored;

pub const Publication = struct {
    restored: Restored,
    descriptors: ?ir.FunctionStorage.Descriptors,
};

pub fn materialize(nodes: *Nodes, module: *const Artifact.Module, path: []const u8, tables: result.Tables, candidate: ?ir.FunctionId, structure: Nodes.Structure) Artifact.Error!Publication {
    const source = if (module.function) |*value| value else null;
    var view: remap.FunctionView(Body) = undefined;
    var control_source: ?Control = null;

    if (source) |value| {
        if (structure == .unchecked and !remap.validFunctionColumns(value)) return error.InvalidModule;

        view.init(nodes, value, candidate);

        if (value.body.root != null) control_source = zx.columns.pointer(Control, value.body.control);
    }

    const stores = zx.columns.columns(Stores, module.stores);
    var surface: Surface(std.meta.Child(@FieldType(Input, "surface"))) = undefined;

    surface.init(module, nodes.types);
    errdefer surface.release(nodes.allocator);

    const input: Input = .{
        .body = if (source != null) &view.input else null,
        .control = control_source,
        .stores = &stores,
        .reuse_store_types = if (source) |value| sameColumn(module.stores.types, value.stores.types) else false,
        .surface = &surface.input,
    };

    const prepared = zx.columns.invoke(generated.executeValue, nodes.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const plan = prepared orelse return error.InvalidModule;

    const body = if (plan.body) |mapped|
        Nodes.materializeBody(source.?, mapped, Nodes.controlBody(source.?.body.root, plan.control))

    else
        null;

    const store_table = zx.columns.view(ir.StoreTable, plan.stores);
    const recursive = if (plan.body) |mapped| mapped.recursive else null;

    const descriptors: ?ir.FunctionStorage.Descriptors = if (recursive != null) .{
        .symbols = zx.columns.pointer(*const ir.SymbolTable, plan.body.?.symbols),
        .expressions = zx.columns.pointer(*const ir.ExpressionTable, plan.body.?.expressions),
        .stores = zx.columns.pointer(*const ir.StoreTable, plan.stores),
        .contracts = zx.columns.pointer(*const ir.ContractTable, plan.body.?.contracts),
    } else null;

    return .{
        .restored = .{
            .program = result.program(path, if (body) |*value| value else null, tables, store_table, surface.exports(), surface.constants()),
            .recursive = if (recursive) |id| @fromBackingInt(id) else null,
        },
        .descriptors = descriptors,
    };
}

fn sameColumn(left: []const u32, right: []const u32) bool {
    return left.len == right.len and (left.len == 0 or left.ptr == right.ptr);
}
