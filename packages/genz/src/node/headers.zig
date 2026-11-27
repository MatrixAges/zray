const std = @import("std");
pub const Error = std.mem.Allocator.Error || error{InvalidAst};

pub fn Counts(comptime Target: type) type {
    const Payloads = @FieldType(std.meta.Child(Target), "payloads");

    return [@typeInfo(Payloads).@"struct".field_names.len]u32;
}

pub fn check(existing: usize, tags: anytype, offsets: []const u32, counts: []u32, limits: ?[]const u64) Error!void {
    if (tags.len != offsets.len) return error.InvalidAst;
    if (tags.len > std.math.maxInt(u32) - existing) return error.OutOfMemory;

    for (tags, offsets) |tag, offset| {
        const index = @backingInt(tag);

        if (limits) |bounds| if (offset >= bounds[index]) return error.InvalidAst;

        counts[index] += 1;
    }

    if (limits == null) for (tags, offsets) |tag, offset| {
        if (offset >= counts[@backingInt(tag)]) return error.InvalidAst;
    };
}

pub fn mask(comptime Tag: type) u64 {
    // A small enum's byte can contain padding above its backing integer.
    return std.math.maxInt(@Int(.unsigned, @bitSizeOf(Tag)));
}
