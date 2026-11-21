const read = @import("rows.zig").readColumn;
const write = @import("write_column.zig").write;
const IndexError = error{IndexOutOfBounds};

pub const Value = union(enum) {
    integer: u64,
    negative_integer: u64,
    float: f64,
    string: []const u8,
    boolean: bool,
    enumeration: u32,
};

pub inline fn readKind(source: *const anyopaque, index: u64) IndexError!u8 {
    const Tag = @typeInfo(Value).@"union".tag_type.?;

    return @intCast(@backingInt(@as(Tag, try read(Value, source, index))));
}

const ReadError = IndexError || error{UnexpectedScalarKind};

pub inline fn readMagnitude(source: *const anyopaque, index: u64) ReadError!u64 {
    return switch (try read(Value, source, index)) {
        .integer, .negative_integer => |magnitude| magnitude,
        else => error.UnexpectedScalarKind,
    };
}

pub inline fn readFloat(source: *const anyopaque, index: u64) ReadError!f64 {
    return switch (try read(Value, source, index)) {
        .float => |value| value,
        else => error.UnexpectedScalarKind,
    };
}

pub inline fn readBoolean(source: *const anyopaque, index: u64) ReadError!bool {
    return switch (try read(Value, source, index)) {
        .boolean => |value| value,
        else => error.UnexpectedScalarKind,
    };
}

pub inline fn readEnumeration(source: *const anyopaque, index: u64) ReadError!u32 {
    return switch (try read(Value, source, index)) {
        .enumeration => |value| value,
        else => error.UnexpectedScalarKind,
    };
}

pub inline fn readText(source: *const anyopaque, index: u64) IndexError!?[]const u8 {
    return switch (try read(Value, source, index)) {
        .string => |text| text,
        else => null,
    };
}

pub inline fn copy(source: *const anyopaque, target: *const anyopaque, index: u64) IndexError!void {
    return copyAt(source, index, target, index);
}

pub inline fn copyAt(source: *const anyopaque, index: u64, target: *const anyopaque, destination: u64) IndexError!void {
    return write(Value, target, destination, try read(Value, source, index));
}

pub inline fn writeText(target: *const anyopaque, index: u64, value: []const u8) IndexError!void {
    return write(Value, target, index, .{ .string = value });
}

pub inline fn writeInteger(target: *const anyopaque, index: u64, value: u64, negative: bool) IndexError!void {
    return write(Value, target, index, if (negative) .{ .negative_integer = value } else .{ .integer = value });
}

pub inline fn writeFloat(target: *const anyopaque, index: u64, value: f64) IndexError!void {
    return write(Value, target, index, .{ .float = value });
}

pub inline fn writeBoolean(target: *const anyopaque, index: u64, value: bool) IndexError!void {
    return write(Value, target, index, .{ .boolean = value });
}

pub inline fn writeEnumeration(target: *const anyopaque, index: u64, value: u32) IndexError!void {
    return write(Value, target, index, .{ .enumeration = value });
}
