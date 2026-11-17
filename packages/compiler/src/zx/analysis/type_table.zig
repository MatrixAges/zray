const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("parser_options").generated_parser;
const scalars = std.enums.values(ir.Scalar);

const scalar_ids = blk: {
    var ids: [scalars.len]u32 = undefined;

    for (scalars, &ids) |scalar, *id| id.* = @backingInt(scalar);

    break :blk ids;
};

pub const scalar_rows: ir.TypeTable = .{
    .kinds = &@as([scalars.len]u8, @splat(@backingInt(std.meta.Tag(ir.Type).scalar))),
    .first = &scalar_ids,
    .second = &@as([scalars.len]u32, @splat(0)),
    .labels = &@as([scalars.len][]const u8, @splat("")),
};

pub fn initializeScalars(allocator: std.mem.Allocator, target: *ir.TypeStorage) std.mem.Allocator.Error!void {
    const ids = try target.reserveDelta(allocator, scalar_rows);

    @memcpy(ids, scalar_rows.first);
    target.publishDelta(scalar_rows);
}

pub fn copy(allocator: std.mem.Allocator, values: ir.TypeTable) std.mem.Allocator.Error!ir.TypeTable {
    const result = try storage(allocator, values);

    return result.view();
}

pub fn storage(allocator: std.mem.Allocator, values: ir.TypeTable) std.mem.Allocator.Error!ir.TypeStorage {
    if (comptime generated) return @import("semantic/merging/commit.zig").snapshot(allocator, values, true);

    var result: ir.TypeStorage = .{};

    inline for (@typeInfo(ir.TypeStorage).@"struct".field_names) |name| {
        const column = @field(values, name);

        const owned = if (comptime std.mem.eql(u8, name, "labels") or std.mem.eql(u8, name, "field_names") or std.mem.eql(u8, name, "names"))
            try names(allocator, column)
        else
            try allocator.dupe(std.meta.Elem(@TypeOf(column)), column);

        @field(result, name) = @FieldType(ir.TypeStorage, name).fromOwnedSlice(owned);
    }

    return result;
}

/// Copies only the columns of a table whose strings outlive the copy, such as a shared project table that one
/// module's analysis extends; the rows the analysis appends are owned by the copy as usual.
pub fn columns(allocator: std.mem.Allocator, values: ir.TypeTable) std.mem.Allocator.Error!ir.TypeStorage {
    if (comptime generated) return @import("semantic/merging/commit.zig").snapshot(allocator, values, false);

    var result: ir.TypeStorage = .{};

    inline for (@typeInfo(ir.TypeStorage).@"struct".field_names) |name| {
        const column = @field(values, name);

        @field(result, name) = @FieldType(ir.TypeStorage, name).fromOwnedSlice(try allocator.dupe(std.meta.Elem(@TypeOf(column)), column));
    }

    return result;
}

fn names(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error![][]const u8 {
    const result = try allocator.alloc([]const u8, values.len);

    for (values, result) |value, *owned| owned.* = try allocator.dupe(u8, value);

    return result;
}
