const std = @import("std");
const protocol = @import("protocol.zig");
const source = @import("cli_source");
const constants = protocol.constants;
const Message = std.zig.Client.Message;

comptime {
    if (@sizeOf(Message.Header) != 2 * @sizeOf(u32) or
        @backingInt(Message.Tag.update) != constants.update_tag or
        @backingInt(Message.Tag.exit) != constants.exit_tag)
    {
        @compileError("Unexpected Zig client frame layout");
    }
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8, environment: *const std.process.Environ.Map, mode: protocol.Mode) !protocol.Result {
    var child = try std.process.spawn(io, .{
        .argv = arguments,
        .environ_map = environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    defer child.kill(io);

    var scratch_buffer: [128]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buffer);
    const request = try source.request.executeValue(scratch.allocator(), {});

    std.debug.assert(request.len == 2 * @sizeOf(Message.Header));

    try child.stdin.?.writeStreamingAll(io, request);

    child.stdin.?.close(io);

    child.stdin = null;
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;

    reader.init(allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();

    const pipes = &reader;

    if (!try source.backend_capture.executeIn(allocator, @ptrCast(&pipes))) return error.BackendOutputTooLarge;

    try reader.checkAnyError();

    var result = try protocol.decodeFrames(allocator, reader.reader(0).buffered(), try child.wait(io), mode);
    const stderr = reader.reader(1);

    if (stderr.bufferedLen() != 0) {
        const storage = stderr.buffer;
        result.stderr = stderr.buffered();
        result.captured_stderr = if (allocator.resize(storage, stderr.end)) storage[0..stderr.end] else storage;
        stderr.buffer = &.{};
    }

    return result;
}

pub fn readChunk(handle: *const anyopaque, reserve: u64) error{ Canceled, ConcurrencyUnavailable, Timeout }!?u64 {
    const pipes: *const *std.Io.File.MultiReader = @ptrCast(@alignCast(handle));
    const reader = pipes.*;

    reader.fill(@intCast(reserve), .none) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |failure| return failure,
    };

    return @max(reader.reader(0).bufferedLen(), reader.reader(1).bufferedLen());
}
