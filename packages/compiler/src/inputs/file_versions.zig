const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const retention = @import("frontend").cache_retention;
const generated = @import("parser_options").generated_parser;
const seed = @import("file_versions/seed.zig");
pub const Version = struct { text: []const u8, mark: u64 };
pub const Counters = struct { active: usize = 0, publishable: usize = 0, abortable: usize = 0 };

pub const Read = struct {
    previous: ?Version,
    text: []const u8,
    borrowable: bool,
    clock: retention.Clock,
    counters: Counters,
};

pub const Update = struct { reuse: bool, mark: u64, previous: ?retention.Retention, counters: Counters };
pub const Retired = struct { count: usize = 0, bytes: usize = 0 };
pub const Digest = enum { Hash, Reuse, Save };

pub fn update(read: Read) Update {
    if (comptime !generated) return seed.update(read);

    const rule = @import("generated_input_file_update");
    const Input = std.meta.Child(rule.Input);
    const Previous = std.meta.Child(@typeInfo(@FieldType(Input, "previous")).optional.child);
    const previous: Previous = if (read.previous) |version| .{ .text = version.text, .mark = version.mark } else undefined;

    const input: Input = .{
        .previous = if (read.previous != null) &previous else null,
        .text = read.text,
        .borrowable = read.borrowable,
        .clock = &.{ .current = read.clock.current, .published = read.clock.published },
        .counters = &.{ .active = read.counters.active, .publishable = read.counters.publishable, .abortable = read.counters.abortable },
    };

    var buffer: [1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return .{
        .reuse = result.reuse,
        .mark = result.mark,
        .previous = if (result.previous) |version| .{ .keep_on_publish = version.keep_on_publish, .keep_on_abort = version.keep_on_abort } else null,
        .counters = .{
            .active = @intCast(result.counters.active),
            .publishable = @intCast(result.counters.publishable),
            .abortable = @intCast(result.counters.abortable),
        },
    };
}

pub fn retire(pending: anytype, kept_arg: [][]u8, published: bool) Retired {
    if (pending.len == 0) return .{};
    if (comptime !generated) return seed.retire(pending, kept_arg, published);

    var kept = kept_arg;
    const rule = @import("generated_input_file_retire");
    const texts = memory.borrowReadColumn([]u8, "text", pending);
    var clear = memory.borrowWriteColumn([]const u8, "text", pending);
    const publish = memory.borrowNestedColumn(bool, &.{ "retention", "keep_on_publish" }, pending);
    const abort = memory.borrowNestedColumn(bool, &.{ "retention", "keep_on_abort" }, pending);

    const input: std.meta.Child(rule.Input) = .{
        .pending = &.{
            .texts = @ptrCast(&texts),
            .clear = @ptrCast(&clear),
            .publish = @ptrCast(&publish),
            .abort = @ptrCast(&abort),
            .count = pending.len,
        },
        .kept = @ptrCast(&kept),
        .published = published,
    };

    var buffer: [128]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return .{ .count = @intCast(result.count), .bytes = @intCast(result.bytes) };
}

pub fn digest(stored: []const u8, text: []const u8, cached: bool) Digest {
    if (comptime !generated) {
        if (stored.ptr != text.ptr or stored.len != text.len) return .Hash;

        return if (cached) .Reuse else .Save;
    }

    const rule = @import("generated_input_file_digest");
    const input: std.meta.Child(rule.Input) = .{ .stored = stored, .text = text, .cached = cached };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return switch (result) {
        .Hash => .Hash,
        .Reuse => .Reuse,
        .Save => .Save,
    };
}
