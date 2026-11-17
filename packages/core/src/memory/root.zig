const std = @import("std");
const rows = @import("rows.zig");
pub const NamedId = rows.NamedId;
pub const borrowNamedRows = rows.borrow;
pub const TextColumn = rows.TextColumn;
const references = @import("reference_column.zig");
pub const borrowReferenceColumn = references.borrow;
pub const readReferencedOptionalBytes = references.readOptionalBytes;
pub const readReferencedBytes = references.readBytes;
pub const IndirectTextColumn = rows.IndirectTextColumn;
pub const ReadColumn = rows.ReadColumn;
pub const borrowTextColumn = rows.borrowText;
pub const borrowTextSlice = rows.borrowTextSlice;
pub const borrowIndirectTextColumn = rows.borrowIndirectText;
pub const borrowReadColumn = rows.borrowColumn;
pub const borrowNestedColumn = rows.borrowNested;
pub const borrowOptionalU32Column = rows.borrowOptionalU32;
pub const borrowOptionalU8Column = rows.borrowOptionalU8;
pub const borrowListColumn = rows.borrowList;
pub const borrowNestedListColumn = rows.borrowNestedList;
pub const readTextColumn = rows.readText;
pub const readOptionalTextColumn = rows.readOptionalText;
pub const readTextListColumn = rows.readTextList;
pub const readIndirectTextColumn = rows.readIndirectText;
pub const readOptionalIndirectTextColumn = rows.readOptionalIndirectText;
pub const readColumnU8 = rows.readColumnU8;
pub const readColumnBool = rows.readColumnBool;
pub const readColumnI32 = rows.readColumnI32;
pub const readColumnU32 = rows.readColumnU32;
pub const readColumnU64 = rows.readColumnU64;
pub const readColumnOptionalU32 = rows.readColumnOptionalU32;
pub const readColumnOptionalU8 = rows.readColumnOptionalU8;
pub const listLength = rows.listLength;
pub const readListText = rows.readListText;
pub const borrowListBytes = rows.borrowListBytes;
pub const readListOptionalU32 = rows.readListOptionalU32;
pub const readRowName = rows.readName;
pub const readRowId = rows.readId;
pub const writeNamedRow = rows.write;
const column = @import("write_column.zig");
pub const WriteColumn = column.Column;
pub const borrowWriteColumn = column.borrow;
pub const writeColumnU8 = column.writeU8;
pub const writeColumnU32 = column.writeU32;
pub const writeColumnU64 = column.writeU64;
pub const writeColumnBytes = column.writeBytes;
pub const writeColumnOptionalU32 = column.writeOptionalU32;
pub const writeColumnOptionalU8 = column.writeOptionalU8;
pub const writeColumnOptionalText = column.writeOptionalText;

pub inline fn borrowU8Range(source: []const u8, first: u64, count: u64) error{IndexOutOfBounds}![]const u8 {
    return borrowRange(u8, source, first, count);
}

pub inline fn borrowU32Range(source: []const u32, first: u64, count: u64) error{IndexOutOfBounds}![]const u32 {
    return borrowRange(u32, source, first, count);
}

pub inline fn borrowStringRange(source: []const []const u8, first: u64, count: u64) error{IndexOutOfBounds}![]const []const u8 {
    return borrowRange([]const u8, source, first, count);
}

inline fn borrowRange(comptime T: type, source: []const T, first: u64, count: u64) error{IndexOutOfBounds}![]const T {
    if (first > source.len or count > source.len - first) return error.IndexOutOfBounds;

    return source[@intCast(first)..][0..@intCast(count)];
}

pub inline fn copyBytes(target: *const anyopaque, offset: u64, source: []const u8, start: u64, end: u64) error{IndexOutOfBounds}!u64 {
    const output: *const []u8 = @ptrCast(@alignCast(target));

    if (start > end or end > source.len or offset > output.len) return error.IndexOutOfBounds;

    const count = end - start;

    if (count > output.len - offset) return error.IndexOutOfBounds;

    @memmove(output.*[@intCast(offset)..][0..@intCast(count)], source[@intCast(start)..@intCast(end)]);

    return count;
}

pub inline fn writeUtf8Scalar(target: *const anyopaque, offset: u64, codepoint: u64) error{ IndexOutOfBounds, InvalidUnicodeScalar }!u64 {
    const output: *const []u8 = @ptrCast(@alignCast(target));
    const scalar = std.math.cast(u21, codepoint) orelse return error.InvalidUnicodeScalar;
    const count = std.unicode.utf8CodepointSequenceLength(scalar) catch return error.InvalidUnicodeScalar;

    if (offset > output.len or count > output.len - offset) return error.IndexOutOfBounds;

    return std.unicode.utf8Encode(scalar, output.*[@intCast(offset)..]) catch return error.InvalidUnicodeScalar;
}

pub inline fn writeU32(target: *const anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    return write(u32, target, index, value);
}

pub inline fn writeU8(target: *const anyopaque, index: u64, value: u8) error{IndexOutOfBounds}!void {
    return write(u8, target, index, value);
}

pub inline fn writeU64(target: *const anyopaque, index: u64, value: u64) error{IndexOutOfBounds}!void {
    return write(u64, target, index, value);
}

pub inline fn writeOptionalU32(target: *const anyopaque, index: u64, value: ?u32) error{IndexOutOfBounds}!void {
    return write(?u32, target, index, value);
}

pub inline fn writeString(target: *const anyopaque, index: u64, value: []const u8) error{IndexOutOfBounds}!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeOptionalString(target: *const anyopaque, index: u64, value: ?[]const u8) error{IndexOutOfBounds}!void {
    return write(?[]const u8, target, index, value);
}

pub inline fn writeU32List(target: *const anyopaque, index: u64, value: []const u32) error{IndexOutOfBounds}!void {
    return write([]const u32, target, index, value);
}

pub inline fn writeStringList(target: *const anyopaque, index: u64, value: []const []const u8) error{IndexOutOfBounds}!void {
    return write([]const []const u8, target, index, value);
}

/// Copies text into an exclusively borrowed destination and releases partial copies on failure.
pub fn copyStrings(allocator: std.mem.Allocator, target: *const anyopaque, source: []const []const u8) (std.mem.Allocator.Error || error{IndexOutOfBounds})!void {
    const output: *const [][]const u8 = @ptrCast(@alignCast(target));

    if (source.len != output.len) return error.IndexOutOfBounds;

    var copied: usize = 0;

    errdefer for (output.*[0..copied]) |text| allocator.free(text);

    for (source, output.*) |text, *item| {
        item.* = try allocator.dupe(u8, text);
        copied += 1;
    }
}

// The caller exclusively lends a descriptor for a mutable slice for the duration of the call.
inline fn write(comptime T: type, target: *const anyopaque, index: u64, value: T) error{IndexOutOfBounds}!void {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (index >= buffer.len) return error.IndexOutOfBounds;

    buffer.*[@intCast(index)] = value;
}

pub inline fn readU32(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return read(u32, target, index);
}

pub inline fn readU64(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return read(u64, target, index);
}

inline fn read(comptime T: type, target: *const anyopaque, index: u64) error{IndexOutOfBounds}!T {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (index >= buffer.len) return error.IndexOutOfBounds;

    return buffer.*[@intCast(index)];
}
