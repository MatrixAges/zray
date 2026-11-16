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
    var writer: std.Io.Writer = .fixed(buffer);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(frame.Input) = .{
        .writer = @ptrCast(&writer),
        .compiler = compiler,
        .key = key,
        .size = size,
        .reading = false,
    };

    const checked = columns.invoke(frame.executeValue, empty.allocator(), &input) catch |err| {
        std.debug.panic("generation cache header could not be encoded: {s}", .{@errorName(err)});
    };

    if (!checked.accepted) return null;

    return .{ .bytes = writer.buffered(), .payload_size = @intCast(checked.payload_size) };
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
