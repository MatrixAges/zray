const std = @import("std");
const analyze = @import("generated_paths").executeValue;
const write = @import("generated_path_write").executeValue;
const Request = Input(analyze);
const Kind = @FieldType(Request, "kind");
const Error = error{ InvalidPath, OutOfMemory };
const Plan = @typeInfo(@typeInfo(@TypeOf(analyze)).@"fn".return_type.?).error_union.payload;

pub fn normalize(allocator: std.mem.Allocator, path: []const u8, kind: Kind, suffix: []const u8) Error![]const u8 {
    return resolve(allocator, &.{}, path, kind, suffix);
}

pub fn validate(path: []const u8, kind: Kind, suffix: []const u8) Error!void {
    _ = try plan(.{ .directory = &.{}, .path = path, .kind = kind, .suffix = suffix });
}

fn plan(request: Request) Error!Plan {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = invoke(analyze, empty.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (!result.valid) return error.InvalidPath;

    return result;
}

pub fn resolve(allocator: std.mem.Allocator, directory: []const u8, path: []const u8, kind: Kind, suffix: []const u8) Error![]const u8 {
    const result = try plan(.{ .directory = directory, .path = path, .kind = kind, .suffix = suffix });
    const length = std.math.cast(usize, result.length) orelse return error.OutOfMemory;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const emit: Input(write) = .{
        .directory = directory,
        .path = path,
        .suffix = result.suffix,
        .attached = result.attached,
        .collect = true,
    };

    const completed = invoke(write, scratch.allocator(), &emit) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    std.debug.assert(completed.parents == 0 and completed.length == length and completed.text.len == length);

    return try allocator.dupe(u8, completed.text);
}

fn Input(comptime function: anytype) type {
    const Parameter = @typeInfo(@TypeOf(function)).@"fn".param_types[1].?;

    return if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
}

inline fn invoke(comptime function: anytype, allocator: std.mem.Allocator, input: *const Input(function)) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const Parameter = @typeInfo(@TypeOf(function)).@"fn".param_types[1].?;

    return function(allocator, if (@typeInfo(Parameter) == .pointer) input else input.*);
}
