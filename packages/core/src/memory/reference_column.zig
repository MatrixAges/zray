const std = @import("std");
const Self = @This();
const IndexError = error{IndexOutOfBounds};

items: []const [*]const u8,
offset: usize,
size: usize,
pub inline fn borrow(comptime field: []const u8, items: anytype) Self {
    const Pointer = @typeInfo(std.meta.Child(@TypeOf(items))).pointer;
    const Field = @FieldType(Pointer.child, field);

    comptime {
        if (Pointer.size != .one or Pointer.attrs.@"allowzero") @compileError("Expected non-null row pointers");

        if (Field != ?[]const u8 and (@typeInfo(Field) != .array or @typeInfo(Field).array.child != u8)) {
            @compileError("Expected optional text or an inline byte array");
        }
    }

    return .{
        .items = @ptrCast(items),
        .offset = @offsetOf(Pointer.child, field),
        .size = @sizeOf(Field),
    };
}

pub inline fn readOptionalBytes(source: *const anyopaque, index: u64) IndexError!?[]const u8 {
    const column: *const Self = @ptrCast(@alignCast(source));
    const field = try column.at(index);

    return @as(*align(1) const ?[]const u8, @ptrCast(field)).*;
}

pub inline fn readBytes(source: *const anyopaque, index: u64) IndexError![]const u8 {
    const column: *const Self = @ptrCast(@alignCast(source));
    const field = try column.at(index);

    return field[0..column.size];
}

inline fn at(self: *const Self, index: u64) IndexError![*]const u8 {
    if (index >= self.items.len) return error.IndexOutOfBounds;

    return self.items[@intCast(index)] + self.offset;
}
