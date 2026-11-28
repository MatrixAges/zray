const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const entry = if (generated) @import("generated_publication_name") else void;
const Kind = if (generated) @FieldType(std.meta.Child(entry.Input), "kind") else enum { Public, Store };
const Self = @This();

identity: []const u8,
module: []const u8,
pub fn create(allocator: std.mem.Allocator, comptime kind: Kind, name: []const u8) std.mem.Allocator.Error!Self {
    const width = zx.Sha256.digest_length;
    var bytes: [width + width * 2]u8 = undefined;

    if (generated) {
        var scratch = std.heap.FixedBufferAllocator.init(&bytes);
        const input: std.meta.Child(entry.Input) = .{ .kind = kind, .identity = name };

        const parts = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        return pack(allocator, name, parts.prefix, parts.digest);
    }

    zx.Sha256.hash(name, bytes[0..width], .{});

    const hex = std.fmt.bytesToHex(bytes[0..width].*, .lower);

    return pack(allocator, name, if (kind == .Public) "public_" else "zxc_store_initial_", &hex);
}

pub fn pack(allocator: std.mem.Allocator, name: []const u8, prefix: []const u8, digest: []const u8) std.mem.Allocator.Error!Self {
    const data = try std.mem.concat(allocator, u8, &.{ prefix, digest, name });
    const end = data.len - name.len;

    return .{ .module = data[0..end], .identity = data[end..] };
}
