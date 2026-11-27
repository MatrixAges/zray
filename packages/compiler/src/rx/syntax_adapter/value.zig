const std = @import("std");

pub fn materialize(comptime decode: anytype, allocator: std.mem.Allocator, source: []const u8, parts: anytype, length: u64) std.mem.Allocator.Error![]const u8 {
    if (length == 0) return &.{};

    const Parameter = @typeInfo(@TypeOf(decode)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const input: Input = .{ .source = source, .parts = parts };
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const output = decode(arena.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    std.debug.assert(output.len == length);

    return try allocator.dupe(u8, output);
}

pub fn raw(source: []const u8, value: anytype) []const u8 {
    return source[@intCast(value.span.start)..@intCast(value.span.end)];
}

pub fn select(original: []const u8, decoded: []const u8, value: anytype) []const u8 {
    if (value.decoded_start == value.decoded_end) return original;

    return decoded[@intCast(value.decoded_start)..@intCast(value.decoded_end)];
}
