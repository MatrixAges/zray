const std = @import("std");
pub const Rows = []const [*]const u8;
const IndexError = error{IndexOutOfBounds};

pub fn borrow(items: anytype) Rows {
    const pointer = @typeInfo(std.meta.Elem(@TypeOf(items))).pointer;

    comptime if (pointer.size != .one or pointer.attrs.@"allowzero") @compileError("Expected non-null row pointers");

    return @ptrCast(items);
}

pub inline fn count(source: *const anyopaque) u64 {
    return rows(source).len;
}

pub inline fn same(left: *const anyopaque, right: *const anyopaque, left_row: u64, right_row: u64) IndexError!bool {
    return try at(left, left_row) == try at(right, right_row);
}

pub inline fn range(source: *const anyopaque, first: u64, end: u64) IndexError![]const u8 {
    const references = rows(source);

    if (first > end or end > references.len) return error.IndexOutOfBounds;

    return std.mem.sliceAsBytes(references[@intCast(first)..@intCast(end)]);
}

pub inline fn nested(source: anytype, row: u64, offset: u64) IndexError!@TypeOf(source) {
    return @ptrCast(try field(Rows, try at(source, row), offset));
}

pub inline fn select(source: *const anyopaque, row: u64, shape: anytype) IndexError!std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(try at(source, row));
}

pub inline fn bytes(source: *const anyopaque, offset: u64, width: u64) IndexError![]const u8 {
    const slice = (try field([]const u8, @ptrCast(source), offset)).*;
    const length = std.math.mul(usize, slice.len, std.math.cast(usize, width) orelse return error.IndexOutOfBounds) catch return error.IndexOutOfBounds;

    return slice.ptr[0..length];
}

pub inline fn optionalU32(source: *const anyopaque, offset: u64) IndexError![]const ?u32 {
    return (try field([]const ?u32, @ptrCast(source), offset)).*;
}

pub inline fn text(source: *const anyopaque, offset: u64) IndexError![]const []const u8 {
    return (try field([]const []const u8, @ptrCast(source), offset)).*;
}

pub inline fn borrowedText(row: []const u8, offset: u64) IndexError![]const u8 {
    return borrowedField([]const u8, row, offset);
}

pub inline fn borrowedOptionalText(row: []const u8, offset: u64) IndexError!?[]const u8 {
    return borrowedField(?[]const u8, row, offset);
}

pub inline fn sameBorrowedBytes(left: []const u8, right: []const u8) bool {
    return left.ptr == right.ptr and left.len == right.len;
}

pub inline fn borrowedReference(row: []const u8, offset: u64, width: u64) IndexError!?[]const u8 {
    const pointer = (try borrowedField(?[*]const u8, row, offset)) orelse return null;

    return pointer[0..std.math.cast(usize, width) orelse return error.IndexOutOfBounds];
}

inline fn borrowedField(comptime T: type, row: []const u8, offset: u64) IndexError!T {
    if (offset > row.len or row.len - offset < @sizeOf(T)) return error.IndexOutOfBounds;

    return (try field(T, row.ptr, offset)).*;
}

pub inline fn borrowedList(row: []const u8, offset: u64, width: u64) IndexError![]const u8 {
    const slice = try borrowedText(row, offset);
    const length = std.math.mul(usize, slice.len, std.math.cast(usize, width) orelse return error.IndexOutOfBounds) catch return error.IndexOutOfBounds;

    return slice.ptr[0..length];
}

pub inline fn appendByteView(resource: *const anyopaque, storage: *const anyopaque, bytes_view: []const u8) std.mem.Allocator.Error!void {
    const target: *std.ArrayList([]const u8) = @ptrCast(@alignCast(@constCast(storage)));

    try target.append(@import("column_set.zig").borrowAllocator(resource), bytes_view);
}

pub inline fn popByteView(storage: *const anyopaque) ?[]const u8 {
    const target: *std.ArrayList([]const u8) = @ptrCast(@alignCast(@constCast(storage)));

    return target.pop();
}

inline fn rows(source: *const anyopaque) Rows {
    return @as(*const Rows, @ptrCast(@alignCast(source))).*;
}

inline fn at(source: *const anyopaque, row: u64) IndexError![*]const u8 {
    const references = rows(source);

    if (row >= references.len) return error.IndexOutOfBounds;

    return references[@intCast(row)];
}

inline fn field(comptime T: type, item: [*]const u8, offset: u64) IndexError!*const T {
    const position = std.math.cast(usize, offset) orelse return error.IndexOutOfBounds;

    return @ptrCast(@alignCast(item + position));
}
