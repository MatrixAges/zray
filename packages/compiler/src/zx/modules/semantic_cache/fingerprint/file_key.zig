const std = @import("std");
const zx = @import("zx");

pub fn path(allocator: std.mem.Allocator, directory: []const u8, key: []const u8, native: bool) std.mem.Allocator.Error![]u8 {
    if (comptime !@import("parser_options").generated_parser) {
        var hash: [32]u8 = undefined;

        zx.Sha256.hash(key, &hash, .{});

        const digest = std.fmt.bytesToHex(hash, .lower);

        return std.fmt.allocPrint(allocator, "{s}/{s}{s}.cache", .{ directory, if (native) "native/" else "", &digest });
    }

    const entry = @import("generated_semantic_file_key");
    var scratch_memory: [512]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_memory);

    const name = entry.executeIn(scratch.allocator(), &.{ .native = native, .key = key }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
}
