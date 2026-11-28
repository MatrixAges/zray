const std = @import("std");
const Allocating = std.Io.Writer.Allocating;
const Error = std.mem.Allocator.Error;
const Self = @This();

bytes: *Allocating,
json: std.json.Stringify,
pub fn init(bytes: *Allocating) Self {
    return .{ .bytes = bytes, .json = .{ .writer = &bytes.writer, .options = .{ .whitespace = .indent_2 } } };
}

pub fn begin(handle: *anyopaque) Error!void {
    borrow(handle).json.beginObject() catch return error.OutOfMemory;
}

pub fn finish(handle: *anyopaque) Error![]const u8 {
    const self = borrow(handle);

    self.json.endObject() catch return error.OutOfMemory;

    return self.bytes.written();
}

pub fn programTypes(handle: *anyopaque, name: []const u8, input: *const anyopaque) Error!void {
    const program: *const @import("zx").ir.Program = @ptrCast(@alignCast(input));

    try borrow(handle).writeField(name, &program.types);
}

pub fn field(comptime Value: type, comptime indirect: bool) fn (*anyopaque, []const u8, if (indirect) *const anyopaque else Value) Error!void {
    const Input = if (indirect) *const anyopaque else Value;

    return struct {
        fn write(handle: *anyopaque, name: []const u8, input: Input) Error!void {
            const value = if (indirect) @as(*const Value, @ptrCast(@alignCast(input))) else input;

            try borrow(handle).writeField(name, value);
        }
    }.write;
}

fn writeField(self: *Self, name: []const u8, value: anytype) Error!void {
    self.json.objectField(name) catch return error.OutOfMemory;
    self.json.write(value) catch return error.OutOfMemory;
}

fn borrow(handle: *anyopaque) *Self {
    return @ptrCast(@alignCast(handle));
}
