const std = @import("std");
const cache_key = @import("cache_key.zig");
const rules = @import("partition_rules");
const Encoded = @TypeOf(std.fmt.bytesToHex(@as(cache_key.Digest, @splat(0)), .lower));

pub const Keys = struct {
    hex: []const []const u8,
    pub fn init(allocator: std.mem.Allocator, digests: []const cache_key.Digest) std.mem.Allocator.Error!Keys {
        const encoded = try allocator.alloc(Encoded, digests.len);
        const hex = try allocator.alloc([]const u8, digests.len);

        for (digests, encoded, hex) |digest, *text, *view| {
            text.* = std.fmt.bytesToHex(digest, .lower);
            view.* = text;
        }

        return .{ .hex = hex };
    }
    /// Replaces presence with the entries safe to record before spawning any worker.
    pub fn pending(self: Keys, allocator: std.mem.Allocator, previous: []const u8, present: []bool) ![]const u32 {
        const bytes = std.mem.sliceAsBytes(present);

        return rules.partition_cache_check.executeValue(allocator, &.{
            .previous = previous,
            .digests = self.hex,
            .present = present,
            .target = @ptrCast(&bytes),
        });
    }
    pub fn write(self: Keys, io: std.Io, allocator: std.mem.Allocator, path: []const u8, valid: []const bool) !void {
        var text = std.Io.Writer.Allocating.init(allocator);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        defer text.deinit();

        try rules.partition_cache_publish.executeValue(empty.allocator(), &.{
            .out = @ptrCast(&text.writer),
            .digests = self.hex,
            .valid = valid,
        });

        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });

        defer file.deinit(io);

        try file.file.writeStreamingAll(io, text.written());
        try file.replace(io);
    }
};

pub fn complete(pending: []const u32, failures: []const ?[]const u8, valid: []bool) !bool {
    const bytes = std.mem.sliceAsBytes(valid);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rules.partition_cache_complete.executeValue(empty.allocator(), &.{
        .pending = pending,
        .failures = failures,
        .target = @ptrCast(&bytes),
    });
}
