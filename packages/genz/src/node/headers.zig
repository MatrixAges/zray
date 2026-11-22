const std = @import("std");
const zx = @import("zx");
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

pub const Views = struct {
    source_tags: []const u8 = &.{},
    source_offsets: []const u32 = &.{},
    target_tags: []u8 = &.{},
    target_offsets: []u32 = &.{},
    pub fn bind(self: *Views, comptime Input: type, allocator: *const std.mem.Allocator, rows: anytype, lengths: *const zx.memory.ColumnLengths) Input {
        const Tag = std.meta.Elem(@TypeOf(rows.tags.items));

        comptime std.debug.assert(@sizeOf(Tag) == @sizeOf(u8) and @alignOf(Tag) == @alignOf(u8));

        var input: Input = undefined;
        input.allocator = @ptrCast(allocator);
        input.tag_storage = @ptrCast(&rows.tags);
        input.offset_storage = @ptrCast(&rows.offsets);
        input.source_tags = @ptrCast(&self.source_tags);
        input.source_offsets = @ptrCast(&self.source_offsets);
        input.target_tags = @ptrCast(&self.target_tags);
        input.target_offsets = @ptrCast(&self.target_offsets);
        input.lengths = @ptrCast(lengths);

        return input;
    }
};

pub fn mask(comptime Tag: type) u64 {
    // A small enum's byte can contain padding above its backing integer.
    return std.math.maxInt(@Int(.unsigned, @bitSizeOf(Tag)));
}
