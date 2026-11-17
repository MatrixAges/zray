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

pub fn appendTypes(allocator: std.mem.Allocator, target: *ir.TypeStorage, delta: anytype) std.mem.Allocator.Error!void {
    try append(allocator, target, null, delta, @as(Origins.Table, .{}));
}

pub fn append(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    try appendWithPayload(allocator, allocator, target, origins, delta, bindings);
}

pub fn appendWithPayload(allocator: std.mem.Allocator, payload: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    const table = zx.columns.view(ir.TypeTable, delta);

    if (origins) |storage| try storage.ensureUnusedCapacity(allocator, bindings.ids.len);

    _ = try target.reserveDelta(allocator, table);

    const offsets: Offsets = .{
        .children = @intCast(target.children.items.len),
        .fields = @intCast(target.field_types.items.len),
        .names = @intCast(target.names.items.len),
    };

    try writeReserved(payload, target, origins, table, bindings, &offsets, .Own);
}

pub fn appendConstructed(allocator: std.mem.Allocator, target: *ir.TypeStorage, table: ir.TypeTable, owns_names: bool) std.mem.Allocator.Error!void {
    _ = try target.reserveDelta(allocator, table);

    try writeReserved(allocator, target, null, table, @as(Origins.Table, .{}), null, if (owns_names) .OwnNames else .Borrow);
}

pub fn snapshot(allocator: std.mem.Allocator, table: ir.TypeTable, comptime own_text: bool) std.mem.Allocator.Error!ir.TypeStorage {
    var target: ir.TypeStorage = .{};

    if (table.count() == 0) return target;

    errdefer target.deinit(allocator);

    inline for (@typeInfo(ir.TypeStorage).@"struct".field_names) |name| {
        try @field(target, name).ensureTotalCapacityPrecise(allocator, @field(table, name).len);
    }

    try writeReserved(allocator, &target, null, table, @as(Origins.Table, .{}), null, if (own_text) .Own else .Borrow);

    return target;
}

fn tail(storage: anytype, comptime name: []const u8, count: usize) @TypeOf(@field(storage.*, name).items) {
    return @field(storage.*, name).unusedCapacitySlice()[0..count];
}

fn writeReserved(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, table: ir.TypeTable, bindings: anytype, offsets: ?*const Offsets, text_mode: TextMode) std.mem.Allocator.Error!void {
    if (table.count() != 0 or table.first.len != 0 or bindings.ids.len != 0) {
        const types = ir.TypeTable.borrow(Table, table);

        const nominal: Bindings = .{
            .ids = bindings.ids,
            .kinds = bindings.kinds,
            .owners = bindings.owners,
            .members = bindings.members,
        };

        const tails = .{
            .kinds = tail(target, "kinds", table.kinds.len),
            .first = tail(target, "first", table.first.len),
            .second = tail(target, "second", table.second.len),
            .labels = tail(target, "labels", table.labels.len),
            .children = tail(target, "children", table.children.len),
            .field_types = tail(target, "field_types", table.field_types.len),
            .field_names = tail(target, "field_names", table.field_names.len),
            .names = tail(target, "names", table.names.len),
        };

        const origin_tails = .{
            .ids = if (origins) |storage| tail(storage, "ids", bindings.ids.len) else &.{},
            .kinds = if (origins) |storage| tail(storage, "kinds", bindings.kinds.len) else &.{},
            .owners = if (origins) |storage| tail(storage, "owners", bindings.owners.len) else &.{},
            .members = if (origins) |storage| tail(storage, "members", bindings.members.len) else &.{},
            .names = if (origins) |storage| tail(storage, "names", bindings.ids.len) else &.{},
        };

        var copied: [1]u64 = .{0};
        const progress: []u64 = &copied;

        errdefer switch (text_mode) {
            .Own => {
                const ordered = .{ tails.labels, tails.field_names, tails.names, origin_tails.owners, origin_tails.members };

                inline for (ordered, 0..) |column, index| {
                    if (index < copied[0]) for (column) |text| allocator.free(text);
                }
            },
            .OwnNames => if (copied[0] != 0) for (tails.names) |text| allocator.free(text),
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
                .ids = @ptrCast(&origin_tails.ids),
                .kinds = @ptrCast(&origin_tails.kinds),
                .owners = @ptrCast(&origin_tails.owners),
                .members = @ptrCast(&origin_tails.members),
                .names = @ptrCast(&origin_tails.names),
            },
            .offsets = offsets,
            .base_labels = target.labels.items,
            .delta_labels = tails.labels,
            .text_mode = text_mode,
            .progress = @ptrCast(&progress),
        };

        zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    }

    target.publishReserved(table);

    if (origins) |storage| {
        _ = storage.ids.addManyAsSliceAssumeCapacity(bindings.ids.len);
        _ = storage.kinds.addManyAsSliceAssumeCapacity(bindings.kinds.len);
        _ = storage.owners.addManyAsSliceAssumeCapacity(bindings.owners.len);
        _ = storage.members.addManyAsSliceAssumeCapacity(bindings.members.len);
        _ = storage.names.addManyAsSliceAssumeCapacity(bindings.ids.len);
    }
}
