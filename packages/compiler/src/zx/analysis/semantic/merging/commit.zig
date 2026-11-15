const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");

pub fn appendTypes(allocator: std.mem.Allocator, target: *ir.TypeStorage, delta: anytype) std.mem.Allocator.Error!void {
    try append(allocator, target, null, delta, @as(Origins.Table, .{}));
}

pub fn append(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    try appendWithPayload(allocator, allocator, target, origins, delta, bindings);
}

pub fn appendWithPayload(allocator: std.mem.Allocator, payload: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    var table: ir.TypeTable = undefined;

    inline for (@typeInfo(ir.TypeTable).@"struct".field_names) |name| {
        @field(table, name) = @field(delta, name);
    }

    if (origins) |storage| try storage.ensureUnusedCapacity(allocator, bindings.ids.len);

    const first = try target.reserveDelta(allocator, table);
    const labels = target.labels.unusedCapacitySlice()[0..table.labels.len];
    const fields = target.field_names.unusedCapacitySlice()[0..table.field_names.len];
    const names = target.names.unusedCapacitySlice()[0..table.names.len];
    const owners: [][]const u8 = if (origins) |storage| storage.owners.unusedCapacitySlice()[0..bindings.owners.len] else &.{};
    const members: [][]const u8 = if (origins) |storage| storage.members.unusedCapacitySlice()[0..bindings.members.len] else &.{};
    const origin_names: [][]const u8 = if (origins) |storage| storage.names.unusedCapacitySlice()[0..bindings.ids.len] else &.{};
    const origin_ids: []u32 = if (origins) |storage| storage.ids.unusedCapacitySlice()[0..bindings.ids.len] else &.{};
    const origin_kinds: []u8 = if (origins) |storage| storage.kinds.unusedCapacitySlice()[0..bindings.kinds.len] else &.{};
    const sources = .{ table.labels, table.field_names, table.names, bindings.owners, bindings.members };
    const tails = .{ labels, fields, names, owners, members };
    const words = .{ table.kinds, table.second, table.children, table.field_types, bindings.ids, bindings.kinds };

    const reserved = .{
        target.kinds.unusedCapacitySlice()[0..table.kinds.len],
        target.second.unusedCapacitySlice()[0..table.second.len],
        target.children.unusedCapacitySlice()[0..table.children.len],
        target.field_types.unusedCapacitySlice()[0..table.field_types.len],
        origin_ids,
        origin_kinds,
    };

    if (first.len != 0 or bindings.ids.len != 0) {
        try materialize(payload, sources, tails, words, reserved, .{
            .kinds = table.kinds,
            .first = table.first,
            .target = &first,
            .children = @intCast(target.children.items.len),
            .fields = @intCast(target.field_types.items.len),
            .names = @intCast(target.names.items.len),
        }, .{
            .ids = bindings.ids,
            .base = target.labels.items,
            .delta = labels,
            .names = &origin_names,
        });
    }

    target.publishReserved(table);

    if (origins) |storage| {
        _ = storage.ids.addManyAsSliceAssumeCapacity(bindings.ids.len);
        _ = storage.kinds.addManyAsSliceAssumeCapacity(bindings.kinds.len);
        _ = storage.owners.addManyAsSliceAssumeCapacity(owners.len);
        _ = storage.members.addManyAsSliceAssumeCapacity(members.len);
        _ = storage.names.addManyAsSliceAssumeCapacity(origin_names.len);
    }
}

const generated = @import("generated_type_merge_publication");
const Input = std.meta.Child(generated.Input);
const Column = std.meta.Child(std.meta.Child(@FieldType(Input, "columns")));
const ByteColumn = std.meta.Child(std.meta.Child(@FieldType(Input, "writes")));

/// Writes owned text straight to a reserved column tail.
pub fn copyNames(allocator: std.mem.Allocator, source: []const []const u8, tail: [][]const u8) std.mem.Allocator.Error!void {
    const rule = @import("generated_type_column_text");
    const Text = std.meta.Child(rule.Input);
    const TextColumn = std.meta.Child(std.meta.Child(@FieldType(Text, "columns")));
    const column: TextColumn = .{ .source = source, .target = @ptrCast(&tail) };
    var position: [1]u64 = .{0};
    const progress: []u64 = &position;
    const input: Text = .{ .columns = &.{&column}, .progress = @ptrCast(&progress) };

    zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

const Rebase = struct {
    kinds: []const u8,
    first: []const u32,
    target: *const []u32,
    children: u32,
    fields: u32,
    names: u32,
};

const Labels = struct {
    ids: []const u32,
    base: []const []const u8,
    delta: []const []const u8,
    names: *const [][]const u8,
};

fn materialize(allocator: std.mem.Allocator, sources: anytype, tails: anytype, words: anytype, reserved: anytype, offsets: Rebase, labels: Labels) std.mem.Allocator.Error!void {
    var columns: [tails.len]Column = undefined;
    var pointers: [tails.len]*const Column = undefined;

    inline for (sources, 0..) |source, index| {
        columns[index] = .{ .source = source, .target = @ptrCast(&tails[index]) };
        pointers[index] = &columns[index];
    }

    var word_columns: [words.len]ByteColumn = undefined;
    var word_pointers: [words.len]*const ByteColumn = undefined;
    var bytes: [words.len][]u8 = undefined;

    inline for (words, reserved, 0..) |source, tail, index| {
        bytes[index] = std.mem.sliceAsBytes(tail);
        word_columns[index] = .{ .source = std.mem.sliceAsBytes(source), .target = @ptrCast(&bytes[index]) };
        word_pointers[index] = &word_columns[index];
    }

    var completed: [1]u64 = .{0};
    const progress: []u64 = &completed;

    errdefer inline for (tails, 0..) |tail, index| {
        if (index < completed[0]) for (tail) |text| allocator.free(text);
    };

    const input: Input = .{
        .columns = &pointers,
        .writes = &word_pointers,
        .progress = @ptrCast(&progress),
        .kinds = offsets.kinds,
        .first = offsets.first,
        .target = @ptrCast(offsets.target),
        .children = offsets.children,
        .fields = offsets.fields,
        .names = offsets.names,
        .origin_ids = labels.ids,
        .base_labels = labels.base,
        .delta_labels = labels.delta,
        .origin_names_out = @ptrCast(labels.names),
    };

    zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
