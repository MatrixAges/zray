const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const Origins = @import("../../../nominal_origins.zig");
const Current = @import("../../restore.zig").Current;
const type_table = @import("../../../../analysis/type_table.zig");
const rebind = @import("../rebind/host.zig");
const marshal = @import("../../../../analysis/constants/input.zig").marshal;
const Input = rebind.TypeRequest;
const Merge = std.meta.Child(@FieldType(Input, "merge"));
const Table = std.meta.Child(@FieldType(Merge, "source"));
const Nominal = std.meta.Child(@FieldType(Merge, "origins"));
const Constants = std.meta.Child(@typeInfo(@FieldType(Input, "current_constants")).optional.child);
const scalar_rows = type_table.scalar_rows;

pub fn prepare(scratch: std.mem.Allocator, module: *const Artifact.Module, current: *const Current, maps: *rebind.Maps, decoded: bool) Artifact.Error!rebind.Prepared {
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
        .mapping = @ptrCast(&maps.types),
    };

    const input: Input = .{
        .merge = &request,
        .current_types = &destination,
        .empty = &empty,
        .current_constants = try marshal(Constants, scratch, current.constant_imports),
        .cached_constants = try marshal(Constants, scratch, module.constant_imports),
        .cached_exports = if (decoded) null else try marshal(Constants, scratch, module.constant_exports),
        .scalar_count = scalar_rows.count(),
        .maximum_count = std.math.maxInt(u32),
        .decoded = decoded,
    };

    return rebind.prepare(scratch, module, current, maps, &input);
}
