const std = @import("std");
const Self = @This();
const envelope = @import("envelope.zig");
const stack_capacity = 256;

io: std.Io,
directory: []const u8,
compiler_hex: [64]u8,
pub fn read(self: Self, allocator: std.mem.Allocator, key: [32]u8) !?[]u8 {
    const key_hex = std.fmt.bytesToHex(key, .lower);
    const path = try self.filePath(allocator, &key_hex);

    defer allocator.free(path);

    const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    defer file.close(self.io);

    const total = try file.length(self.io);

    if (comptime @import("parser_options").generated_parser) {
        const size = envelope.payloadSize(total) orelse return error.InvalidCache;
        var recorded: [envelope.header_width]u8 = undefined;

        if (try file.readPositionalAll(self.io, &recorded, 0) != recorded.len) return error.InvalidCache;
        if (!envelope.matches(&recorded, &self.compiler_hex, &key_hex, size)) return error.InvalidCache;

        return try self.readPayload(allocator, file, size, recorded.len);
    }

    var buffer: [stack_capacity]u8 = undefined;
    const expected = self.seedHeader(&buffer, &key_hex, total, true) orelse return error.InvalidCache;
    var received: [stack_capacity]u8 = undefined;
    const recorded = received[0..expected.bytes.len];

    if (try file.readPositionalAll(self.io, recorded, 0) != recorded.len) return error.InvalidCache;
    if (!std.mem.eql(u8, recorded, expected.bytes)) return error.InvalidCache;

    return try self.readPayload(allocator, file, expected.payload_size, recorded.len);
}

fn readPayload(self: Self, allocator: std.mem.Allocator, file: std.Io.File, size: usize, offset: usize) ![]u8 {
    const source = try allocator.alloc(u8, size);

    errdefer allocator.free(source);

    if (try file.readPositionalAll(self.io, source, offset) != source.len) return error.InvalidCache;

    return source;
}

pub fn write(self: Self, allocator: std.mem.Allocator, key: [32]u8, source: []const u8) !bool {
    const key_hex = std.fmt.bytesToHex(key, .lower);
    var buffer: [stack_capacity]u8 = undefined;

    const header = if (comptime @import("parser_options").generated_parser)
        envelope.prepare(&buffer, &self.compiler_hex, &key_hex, source.len)

    else
        self.seedHeader(&buffer, &key_hex, source.len, false);

    const header_bytes = (header orelse return false).bytes;
    const path = try self.filePath(allocator, &key_hex);

    defer allocator.free(path);

    const directory = std.Io.Dir.cwd();

    const file = directory.createFile(self.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => created: {
            try directory.createDirPath(self.io, self.directory);

            break :created try directory.createFile(self.io, path, .{});
        },
        else => return err,
    };

    defer file.close(self.io);

    try file.writeStreamingAll(self.io, header_bytes);
    try file.writeStreamingAll(self.io, source);

    return true;
}

/// A record is written in place rather than through a temporary file and a rename, which cost more than the write
/// itself. Every record of a key holds the same bytes, and the header holds the source length, so a record cut short
/// or caught mid-write reads as invalid and is generated again.
fn seedHeader(self: *const Self, buffer: []u8, key: []const u8, size: u64, reading: bool) ?envelope.Header {
    const marker = "zxc.zig.source.v2\n";
    const header_size = marker.len + 2 * 65 + 17;
    const maximum_source = 64 * 1024 * 1024;

    if (reading and size < header_size) return null;

    const payload_size = if (reading) size - header_size else size;

    if (payload_size > maximum_source) return null;

    const bytes = std.fmt.bufPrint(buffer, marker ++ "{s}\n{s}\n{x:0>16}\n", .{ &self.compiler_hex, key, payload_size }) catch unreachable;

    return .{ .bytes = bytes, .payload_size = @intCast(payload_size) };
}

fn filePath(self: Self, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.cache", .{ self.directory, key });
}
