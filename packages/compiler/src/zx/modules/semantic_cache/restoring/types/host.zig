const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const Origins = @import("../../../nominal_origins.zig");
const Current = @import("../../restore.zig").Current;
const type_table = @import("../../../../analysis/type_table.zig");
const generated = @import("generated_semantic_restore_types");
const marshal = @import("../../../../analysis/constants/input.zig").marshal;
const Input = std.meta.Child(generated.Input);
const Merge = std.meta.Child(@FieldType(Input, "merge"));
const Table = std.meta.Child(@FieldType(Merge, "source"));
const Nominal = std.meta.Child(@FieldType(Merge, "origins"));
const Constants = std.meta.Child(@typeInfo(@FieldType(Input, "current_constants")).optional.child);
const Plan = std.meta.Child(@typeInfo(@TypeOf(generated.executeValue(undefined, undefined))).error_union.payload);
const scalar_rows = type_table.scalar_rows;

pub fn prepare(scratch: std.mem.Allocator, module: *const Artifact.Module, current: *const Current, mapping: []u32, decoded: bool) Artifact.Error!Plan {
    const current_types = current.types.view();
    const source = ir.TypeTable.borrow(Table, module.types);
    const destination = ir.TypeTable.borrow(Table, current_types);
    const base = ir.TypeTable.borrow(Table, if (current_types.count() == 0) scalar_rows else current_types);
    const empty = ir.TypeTable.borrow(Table, .{});
    const origins = Origins.Table.borrow(Nominal, module.nominal_types);
    const base_origins = Origins.Table.borrow(Nominal, current.origins.items.view());

    const request: Merge = .{
        .source = &source,
        .origins = &origins,
        .names = module.nominal_types.names,
        .base = &base,
        .base_origins = &base_origins,
        .mapping = @ptrCast(&mapping),
    };

    const input: Input = .{
        .merge = &request,
        .current_types = &destination,
        .empty = &empty,
        .current_constants = try marshal(Constants, scratch, current.constant_imports),
        .cached_constants = try marshal(Constants, scratch, module.constant_imports),
        .cached_exports = if (decoded) null else try marshal(Constants, scratch, module.constant_exports),
        .type_ids = mapping,
        .scalar_count = scalar_rows.count(),
        .maximum_count = std.math.maxInt(u32),
        .decoded = decoded,
    };

    const result = zx.columns.invoke(generated.executeValue, scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return result orelse error.InvalidModule;
}

pub fn commit(current: *const Current, payload: std.mem.Allocator, plan: Plan) std.mem.Allocator.Error!void {
    if (current.types.count() == 0) try type_table.initializeScalars(current.allocator, current.types);

    try @import("../../../../analysis/semantic/merging/commit.zig").appendWithPayload(
        current.allocator,
        payload,
        current.types,
        &current.origins.items,
        plan.delta.*,
        plan.origins,
    );
}
