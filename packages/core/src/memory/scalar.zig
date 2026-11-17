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

pub inline fn readText(source: *const anyopaque, index: u64) IndexError!?[]const u8 {
    return switch (try read(Value, source, index)) {
        .string => |text| text,
        else => null,
    };
}

pub inline fn copy(source: *const anyopaque, target: *const anyopaque, index: u64) IndexError!void {
    return write(Value, target, index, try read(Value, source, index));
}

pub inline fn writeText(target: *const anyopaque, index: u64, value: []const u8) IndexError!void {
    return write(Value, target, index, .{ .string = value });
}
