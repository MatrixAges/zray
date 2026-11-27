const read = @import("rows.zig").readColumn;
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
