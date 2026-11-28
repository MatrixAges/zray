const std = @import("std");
const zx = @import("zx");
const errors = @import("errors.zig");

pub fn snapshot(comptime Object: type, values: anytype) Object {
    var object: Object = undefined;

    inline for (@typeInfo(Object).@"struct".field_names) |name| {
        @field(object, name) = if (comptime @hasField(@TypeOf(values), name)) @field(values, name) else null;
    }

    return object;
}

pub fn run(comptime entry: type, backing: std.mem.Allocator, input: entry.Input, host: anytype) zx.Error!void {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    return entry.executeIn(scratch.allocator(), input, host) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => errors.errorSet(err),
    };
}
