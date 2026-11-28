const std = @import("std");
const Self = @This();
const execute = @import("generated_byte_index_slot").executeValue;
const Parameter = @typeInfo(@TypeOf(execute)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Slot = @typeInfo(@TypeOf(execute(undefined, undefined))).error_union.payload;
const capacity_ratio = 2;
pub const empty: Self = .{ .keys = &.{}, .buckets = &.{} };

keys: [][]const u8,
buckets: []u64,

owns_keys: bool = true,
pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    if (count == 0) return empty;

    const keys = try allocator.alloc([]const u8, count);

    errdefer allocator.free(keys);

    return .{ .keys = keys, .buckets = try bucketsFor(allocator, count) };
}

pub fn bucketsFor(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]u64 {
    if (count == 0) return &.{};

    const desired = std.math.mul(usize, count, capacity_ratio) catch return error.OutOfMemory;
    const capacity = std.math.ceilPowerOfTwo(usize, desired) catch return error.OutOfMemory;
    const buckets = try allocator.alloc(u64, capacity);

    @memset(buckets, 0);

    return buckets;
}

pub fn borrowKeys(allocator: std.mem.Allocator, keys: [][]const u8) std.mem.Allocator.Error!Self {
    return .{ .keys = keys, .buckets = try bucketsFor(allocator, keys.len), .owns_keys = false };
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.buckets);

    if (self.owns_keys) allocator.free(self.keys);
}

pub fn claim(self: *Self, row: usize, key: []const u8) bool {
    const found = self.locate(key);

    if (found.entry != 0) return false;

    const publish = @import("generated_source_index_publish");
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const entry = publish.executeValue(scratch.allocator(), &.{ .length = row }) catch unreachable;

    self.keys[row] = key;

    self.buckets[@intCast(found.slot)] = entry;

    return true;
}

/// Registers the borrowed paths in an empty index and identifies the first duplicate.
pub fn registerPaths(self: *Self, allocator: std.mem.Allocator, paths: *const @import("zx").memory.TextColumn) std.mem.Allocator.Error!?usize {
    const generated = @import("generated_byte_index_unique");
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const input: std.meta.Child(generated.Input) = .{
        .count = self.keys.len,
        .capacity = self.buckets.len,
        .source = @ptrCast(paths),
    };

    const indexed = @import("zx").columns.invoke(generated.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (indexed.duplicate) |row| return @intCast(row);

    @memcpy(self.keys, indexed.keys);
    @memcpy(self.buckets, indexed.buckets);

    return null;
}

pub fn get(self: *const Self, key: []const u8) ?usize {
    if (self.buckets.len == 0) return null;

    const found = self.locate(key);

    return if (found.entry == 0) null else @intCast(found.entry - 1);
}

fn locate(self: *const Self, key: []const u8) Slot {
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .keys = self.keys,
        .buckets = @ptrCast(&self.buckets),
        .capacity = self.buckets.len,
        .key = key,
        .rows = null,
    };

    return execute(scratch.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch unreachable;
}
