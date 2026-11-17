const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const rule = @import("generated_type_merge_publication");
const Input = std.meta.Child(rule.Input);
const Table = std.meta.Child(@FieldType(Input, "delta"));
const Bindings = std.meta.Child(@FieldType(Input, "origins"));
const Offsets = std.meta.Child(@typeInfo(@FieldType(Input, "offsets")).optional.child);
const TextMode = @FieldType(Input, "text_mode");
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const TypeElements = std.meta.Child(@typeInfo(@FieldType(Destination, "elements")).optional.child);
const NominalElements = std.meta.Child(@typeInfo(@FieldType(Destination, "nominal_elements")).optional.child);

pub fn appendTypes(allocator: std.mem.Allocator, target: *ir.TypeStorage, delta: anytype) std.mem.Allocator.Error!void {
    try append(allocator, target, null, delta, @as(Origins.Table, .{}));
}

pub fn append(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    try appendWithPayload(allocator, allocator, target, origins, delta, bindings);
}

pub fn appendWithPayload(allocator: std.mem.Allocator, payload: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    // The Source reservation validates these lengths before the offsets are used.
    const offsets: Offsets = .{
        .children = @truncate(target.children.items.len),
        .fields = @truncate(target.field_types.items.len),
        .names = @truncate(target.names.items.len),
    };

    try write(allocator, payload, target, origins, zx.columns.view(ir.TypeTable, delta), bindings, &offsets, .Own, false);
}

pub fn appendConstructed(allocator: std.mem.Allocator, target: *ir.TypeStorage, table: ir.TypeTable, owns_names: bool) std.mem.Allocator.Error!void {
    try write(allocator, allocator, target, null, table, @as(Origins.Table, .{}), null, if (owns_names) .OwnNames else .Borrow, false);
}

pub fn snapshot(allocator: std.mem.Allocator, table: ir.TypeTable, comptime own_text: bool) std.mem.Allocator.Error!ir.TypeStorage {
    var target: ir.TypeStorage = .{};

    if (table.count() == 0) return target;

    errdefer target.deinit(allocator);

    try write(allocator, allocator, &target, null, table, @as(Origins.Table, .{}), null, if (own_text) .Own else .Borrow, true);

    return target;
}

fn write(allocator: std.mem.Allocator, payload: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, table: ir.TypeTable, bindings: anytype, offsets: ?*const Offsets, text_mode: TextMode, precise: bool) std.mem.Allocator.Error!void {
    const types = ir.TypeTable.borrow(Table, table);

    const nominal: Bindings = .{
        .ids = bindings.ids,
        .kinds = bindings.kinds,
        .owners = bindings.owners,
        .members = bindings.members,
    };

    var tails: ir.TypeTable = .{};
    var nominal_tails: Origins.Table = .{};
    const slots = zx.memory.bindColumnRanges(TypeElements, target, table, &tails);

    const nominal_slots = if (origins) |storage| zx.memory.bindColumnRanges(NominalElements, storage, .{
        .ids = bindings.ids,
        .kinds = bindings.kinds,
        .owners = bindings.owners,
        .members = bindings.members,
        .names = bindings.ids.len,
    }, &nominal_tails) else undefined;

    const ranges: zx.memory.ColumnRanges = &slots;
    const nominal_ranges: zx.memory.ColumnRanges = &nominal_slots;
    var copied: [1]u64 = .{0};
    const progress: []u64 = &copied;

    errdefer switch (text_mode) {
        .Own => {
            const ordered = .{ tails.labels, tails.field_names, tails.names, nominal_tails.owners, nominal_tails.members };

            inline for (ordered, 0..) |column, index| {
                if (index < copied[0]) for (column) |text| payload.free(text);
            }
        },
        .OwnNames => if (copied[0] != 0) for (tails.names) |text| payload.free(text),
        .Borrow => {},
    };

    const input: Input = .{
        .delta = &types,
        .origins = &nominal,
        .target = &.{
            .kinds = @ptrCast(&tails.kinds),
            .first = @ptrCast(&tails.first),
            .second = @ptrCast(&tails.second),
            .labels = @ptrCast(&tails.labels),
            .children = @ptrCast(&tails.children),
            .field_types = @ptrCast(&tails.field_types),
            .field_names = @ptrCast(&tails.field_names),
            .names = @ptrCast(&tails.names),
        },
        .nominal = &.{
            .ids = @ptrCast(&nominal_tails.ids),
            .kinds = @ptrCast(&nominal_tails.kinds),
            .owners = @ptrCast(&nominal_tails.owners),
            .members = @ptrCast(&nominal_tails.members),
            .names = @ptrCast(&nominal_tails.names),
        },
        .offsets = offsets,
        .base_labels = @ptrCast(&target.labels.items),
        .text_mode = text_mode,
        .progress = @ptrCast(&progress),
        .destination = &.{
            .ranges = @ptrCast(&ranges),
            .nominal_ranges = if (origins != null) @ptrCast(&nominal_ranges) else null,
            .elements = null,
            .nominal_elements = null,
            .resource = @ptrCast(&allocator),
            .precise = precise,
        },
    };

    rule.executeIn(payload, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
