const std = @import("std");
const width = std.crypto.hash.Blake3.digest_length * 2;
pub const limit = 8 << 20;

pub fn open(bytes: []const u8, checksum: anytype) ?[]const u8 {
    if (bytes.len < width or bytes.len > limit) return null;

    const payload = bytes[width..];
    const tag = checksum(payload);

    return if (std.mem.eql(u8, bytes[0..width], &tag)) payload else null;
}

pub fn fits(size: usize) bool {
    return size <= limit - width;
}
