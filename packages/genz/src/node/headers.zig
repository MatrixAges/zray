const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;
pub const Error = std.mem.Allocator.Error || error{InvalidAst};

pub fn Counts(comptime Target: type) type {
    const Payloads = @FieldType(std.meta.Child(Target), "payloads");

    return [@typeInfo(Payloads).@"struct".field_names.len]u32;
}

pub fn check(existing: usize, tags: anytype, offsets: []const u32, counts: []u32, limits: ?[]const u64) Error!void {
    if (!generated) {
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

        return;
    }

    const entry = @import("generated_node_header_check");

    const input: std.meta.Child(entry.Input) = .{
        .tags = bytes(tags),
        .offsets = offsets,
        .existing = existing,
        .mask = mask(std.meta.Elem(@TypeOf(tags))),
        .counts = @ptrCast(&counts),
        .variants = counts.len,
        .limits = limits,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const result = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        error.IndexOutOfBounds => return error.InvalidAst,
        else => unreachable,
    };

    return switch (result) {
        .Valid => {},
        .Invalid => error.InvalidAst,
        .Exhausted => error.OutOfMemory,
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

fn bytes(tags: anytype) []const u8 {
    comptime std.debug.assert(@sizeOf(std.meta.Elem(@TypeOf(tags))) == 1);

    return std.mem.sliceAsBytes(tags);
}

pub fn mask(comptime Tag: type) u64 {
    // A small enum's byte can contain padding above its backing integer.
    return std.math.maxInt(@Int(.unsigned, @bitSizeOf(Tag)));
}
