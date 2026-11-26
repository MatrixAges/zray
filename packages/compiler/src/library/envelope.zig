const std = @import("std");
const zx = @import("zx");
const columns = zx.columns;
const layout = @import("generated_library_envelope_layout");
const opening = @import("generated_library_envelope_open");
const sealing = @import("generated_library_envelope_seal");
const header = @import("generated_library_envelope_header");
const versions = @import("generated_library_envelope_versions");

pub const Payload = struct {
    bytes: []const u8,
    maximum_depth: usize,
    legacy: bool,
    current_ir: bool = false,
};

pub fn open(source: []const u8) ?Payload {
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const input: std.meta.Child(opening.Input) = .{ .source = source, .ir_version = @import("zx").ir_version };

    const payload = (columns.invoke(opening.executeValue, scratch.allocator(), &input) catch |err| {
        std.debug.panic("library header could not be checked: {s}", .{@errorName(err)});
    }) orelse return null;

    return .{ .bytes = source[@intCast(payload.start)..], .maximum_depth = @intCast(payload.maximum_depth), .legacy = payload.legacy, .current_ir = payload.current_ir };
}

pub fn encode(allocator: std.mem.Allocator, payload: anytype) std.mem.Allocator.Error![]u8 {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const header_size: usize = @intCast(layout.executeValue(empty.allocator(), {}) catch unreachable);
    var out = try @import("frontend").artifact_json.write(allocator, payload, header_size);

    errdefer out.deinit();

    const encoded = out.writer.buffered();
    var buffer: [512]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);

    const text = sealing.executeValue(scratch.allocator(), encoded[header_size..]) catch |err| {
        std.debug.panic("library header could not be written: {s}", .{@errorName(err)});
    };

    std.debug.assert(text.len == header_size);
    @memcpy(encoded[0..header_size], text);

    return out.toOwnedSlice();
}

pub fn writeFile(io: std.Io, file: std.Io.File, payload: anytype) !void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const header_size = layout.executeValue(empty.allocator(), {}) catch unreachable;
    var writer = file.writer(io, &.{});

    try writer.seekToUnbuffered(header_size);

    var buffer: [16 * 1024]u8 = undefined;
    var hashed = writer.interface.hashed(zx.Sha256.init(.{}), &buffer);

    std.json.Stringify.value(payload, .{}, &hashed.writer) catch return writer.err.?;
    hashed.writer.flush() catch return writer.err.?;

    const digest = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower);
    var scratch_buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buffer);
    const text = header.executeValue(scratch.allocator(), &digest) catch unreachable;

    std.debug.assert(text.len == header_size);

    try file.writePositionalAll(io, text, 0);
}

pub fn compatible(outer: u32, program: u32, expected: u32) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const input: std.meta.Child(versions.Input) = .{ .outer = outer, .program = program, .expected = expected };

    return versions.executeValue(empty.allocator(), &input) catch unreachable;
}
