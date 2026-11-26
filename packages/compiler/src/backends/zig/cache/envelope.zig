const std = @import("std");
const frame = @import("generated_generation_cache_envelope");
const layout = @import("generated_generation_cache_layout");
const inspect = @import("generated_generation_cache_inspect");
const constants = @import("generated_generation_cache_constants").@"zx.constants";
const columns = @import("zx").columns;
pub const Header = struct { bytes: []const u8, payload_size: usize };
pub const header_width: usize = constants.header_width;

comptime {
    if (@import("parser_options").generated_parser) {
        std.debug.assert(constants.marker.len == constants.marker_width);
    }
}

pub fn prepare(buffer: []u8, compiler: []const u8, key: []const u8, size: u64) ?Header {
    var scratch_buffer: [2048]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buffer);

    const input: std.meta.Child(frame.Input) = .{
        .compiler = compiler,
        .key = key,
        .size = size,
        .reading = false,
    };

    const prepared = (frame.executeIn(scratch.allocator(), &input) catch |err| {
        std.debug.panic("generation cache header could not be encoded: {s}", .{@errorName(err)});
    }) orelse return null;

    std.debug.assert(prepared.bytes.len <= buffer.len);
    @memcpy(buffer[0..prepared.bytes.len], prepared.bytes);

    return .{ .bytes = buffer[0..prepared.bytes.len], .payload_size = @intCast(prepared.payload_size) };
}

pub fn payloadSize(total: u64) ?usize {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const input: std.meta.Child(layout.Input) = .{ .size = total, .reading = true };
    const checked = columns.invoke(layout.executeValue, empty.allocator(), &input) catch unreachable;

    return if (checked.accepted) @intCast(checked.payload_size) else null;
}

pub fn matches(header: []const u8, compiler: []const u8, key: []const u8, payload_size: usize) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(inspect.Input) = .{
        .header = header,
        .compiler = compiler,
        .key = key,
        .payload_size = payload_size,
    };

    return columns.invoke(inspect.executeValue, empty.allocator(), &input) catch unreachable;
}
