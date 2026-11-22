const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const Nodes = @import("../../../artifact/nodes.zig");
const remap = @import("../../../artifact/nodes/remap.zig");
const result = @import("../../../link/result/host.zig");
const destination = @import("../../../link/signature/publication/destination.zig");
const verification = @import("../../../artifact/validation/view.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const Current = @import("../../restore.zig").Current;
const TypePlan = @import("../rebind/host.zig").TypePlan;
const TypeTail = @import("../../../../analysis/semantic/merging/publication/view.zig");
const scalar_rows = @import("../../../../analysis/type_table.zig").scalar_rows;
const generated = @import("generated_semantic_restore_publication");
const Input = std.meta.Child(generated.Input);
const Body = std.meta.Child(@typeInfo(@FieldType(Input, "body")).optional.child);
const Control = @typeInfo(@FieldType(Input, "control")).optional.child;
const Stores = std.meta.Child(@FieldType(Input, "stores"));
const Attributes = std.meta.Child(@typeInfo(@FieldType(Input, "attributes")).optional.child);
const Types = std.meta.Child(@FieldType(Input, "types"));
const Table = std.meta.Child(@FieldType(Types, "delta"));
const Nominal = std.meta.Child(@FieldType(Types, "origins"));
const Destination = std.meta.Child(@FieldType(Input, "functions"));
const Empty = std.meta.Child(@FieldType(Input, "empty"));
const Restored = @import("../../restore.zig").Restored;

pub fn materialize(nodes: *Nodes, module: *const Artifact.Module, target: *const Current, temporary: std.mem.Allocator, types: TypePlan, candidate: ?ir.FunctionId, structure: Nodes.Structure) Artifact.Error!Restored {
    const delta = zx.columns.view(ir.TypeTable, types.delta);

    const options: TypeTail.Options = .{
        .allocator = target.allocator,
        .payload = nodes.allocator,
        .types = target.types,
        .origins = &target.origins.items,
        .offsets = &TypeTail.offsets(target.types),
    };

    var type_tail: TypeTail = undefined;

    type_tail.init(&options, delta, types.origins);

    const nominal: Nominal = .{
        .ids = types.origins.ids,
        .kinds = types.origins.kinds,
        .owners = types.origins.owners,
        .members = types.origins.members,
    };

    const type_request: Types = .{
        .target = zx.columns.pointer(@FieldType(Types, "target"), type_tail.target.target),
        .nominal = zx.columns.pointer(@FieldType(Types, "nominal"), type_tail.target.nominal),
        .offsets = zx.columns.pointer(@typeInfo(@FieldType(Types, "offsets")).optional.child, options.offsets.?),
        .base_labels = type_tail.target.base_labels,
        .text_mode = @fromBackingInt(@backingInt(type_tail.target.text_mode)),
        .native_owner = type_tail.target.native_owner,
        .progress = type_tail.target.progress,
        .destination = zx.columns.pointer(@FieldType(Types, "destination"), type_tail.target.destination),
        .payload = type_tail.target.payload,
        .delta = &ir.TypeTable.borrow(Table, delta),
        .origins = &nominal,
        .scalars = if (target.types.count() == 0) &ir.TypeTable.borrow(Table, scalar_rows) else null,
    };

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

    var functions: destination.View(Destination) = undefined;

    functions.init(&target.allocator, target.functions);

    var arena = std.heap.ArenaAllocator.init(temporary);

    defer arena.deinit();

    const scratch = arena.allocator();
    var scope: zx.memory.ArenaScope = .{ .active = nodes.allocator };
    var validation: verification.View(std.meta.Child(@FieldType(Input, "verification"))) = undefined;

    validation.init(.{
        .types = target.types,
        .functions = target.functions,
        .native_modules = &target.native_modules,
        .verified = target.verified.*,
    }, &surface, &scope, &scratch, &nodes.allocator);

    const input: Input = .{
        .body = if (source != null) &view.input else null,
        .control = control_source,
        .attributes = if (source != null) &attributes else null,
        .stores = &stores,
        .types = &type_request,
        .reuse_store_types = if (source) |value| sameColumn(module.stores.types, value.stores.types) else false,
        .surface = &surface.input,
        .functions = &functions.input,
        .empty = &destination.empty(Empty),
        .path = target.path,
        .verification = &validation.input,
    };

    const prepared = generated.executeIn(scope.allocator(), &input) catch |err| return verification.failure(&scope, scratch, err);
    const plan = prepared orelse return error.InvalidModule;
    const verified = plan.verified orelse return error.InvalidIr;

    target.verified.* = .{
        .functions = @intCast(verified.functions),
        .types = zx.columns.view(@import("../../../../ir/validate.zig").TypePrefix, verified.types),
        .native = verified.native,
    };

    const tables: result.Tables = .{
        .types = target.types.view(),
        .functions = target.functions.view(),
        .native_modules = target.native_modules,
    };

    return .{
        .program = result.fromPublication(target.path, plan, tables, surface.exports(), surface.constants()),
        .recursive = if (plan.recursive) |id| @fromBackingInt(id) else null,
    };
}

fn sameColumn(left: []const u32, right: []const u32) bool {
    return left.len == right.len and (left.len == 0 or left.ptr == right.ptr);
}
