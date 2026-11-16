const std = @import("std");
const zx = @import("zx");
const Unit = @import("genz").zx.modules.Unit;
const registration = @import("generated_function_files_register");
pub const Error = std.mem.Allocator.Error || error{ConflictingFunction};

pub fn select(allocator: std.mem.Allocator, names: []const []const u8, units: []const Unit, sources: []const []const u8) Error![]const u64 {
    if (units.len == 0) return &.{};

    const keys = try allocator.alloc([]const u8, units.len);

    for (units, keys) |unit, *key| key.* = names[id(unit)];

    const minimum = std.math.mul(usize, units.len, 2) catch return error.OutOfMemory;
    const capacity = std.math.ceilPowerOfTwo(usize, minimum) catch return error.OutOfMemory;
    const buckets = try allocator.alloc(u64, capacity);
    const selected = try allocator.alloc(u64, units.len);

    @memset(buckets, 0);

    const input: std.meta.Child(registration.Input) = .{
        .keys = keys,
        .sources = sources,
        .capacity = capacity,
        .buckets = @ptrCast(&buckets),
        .selected = @ptrCast(&selected),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = zx.columns.invoke(registration.executeValue, empty.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (!result.valid) return error.ConflictingFunction;

    return selected[0..@intCast(result.count)];
}

pub fn id(unit: Unit) usize {
    return @backingInt(switch (unit) {
        .function, .regular => |function| function,
        else => unreachable,
    });
}
