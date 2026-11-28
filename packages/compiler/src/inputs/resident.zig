const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const seed = @import("resident/seed.zig");
pub const settings = if (generated) @import("generated_resident_constants").@"zx.constants" else seed;
pub const Command = enum { Missing, Unknown, Incomplete, StandardAbi, Manifest, Partitioned, Serve, Warm };
pub const Status = enum(u8) { Done, Failed, Stale, Declined };

pub const Request = struct {
    manifest: []const u8,
    output: []const u8,
    cache: []const u8,
    partitions: u32,
    write: bool = true,
};

pub const Identity = struct {
    size: u64,
    mtime_low: u64,
    mtime_high: u64,
    path: []const u8,
    pub fn init(size: u64, modified: i128, path: []const u8) Identity {
        const bits: u128 = @bitCast(modified);

        return .{ .size = size, .mtime_low = @truncate(bits), .mtime_high = @truncate(bits >> @bitSizeOf(u64)), .path = path };
    }
};

pub const Envelope = struct { caller: Identity, cwd: []const u8, request: Request };

pub fn command(arguments: []const [:0]const u8) Command {
    if (comptime !generated) return seed.command(arguments);

    const rule = @import("generated_resident_command");

    const input: std.meta.Child(rule.Input) = .{
        .count = arguments.len,
        .command = if (arguments.len > 1) arguments[1] else "",
        .option = if (arguments.len > 5) arguments[5] else "",
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const selected = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return @fromBackingInt(@intCast(@backingInt(selected)));
}

pub fn receive(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Envelope {
    if (comptime !generated) return seed.receive(allocator, reader);

    const rule = @import("generated_resident_receive");
    var identity: [3 * @sizeOf(u64)]u8 = undefined;
    var options: [@sizeOf(u32)]u8 = undefined;

    try reader.readSliceAll(&identity);

    var fields: [5][]const u8 = undefined;
    var read: usize = 0;

    errdefer for (fields[0..read]) |field| allocator.free(field);

    for (&fields) |*field| {
        field.* = try readText(allocator, reader);
        read += 1;
    }

    try reader.readSliceAll(&options);

    var scratch: std.heap.ArenaAllocator = .init(allocator);

    defer scratch.deinit();

    const message = try rule.executeValue(scratch.allocator(), &.{
        .identity = &identity,
        .options = &options,
        .path = fields[0],
        .cwd = fields[1],
        .manifest = fields[2],
        .output = fields[3],
        .cache = fields[4],
    });

    return .{
        .caller = .{ .size = message.size, .mtime_low = message.mtime_low, .mtime_high = message.mtime_high, .path = message.path },
        .cwd = message.cwd,
        .request = .{ .manifest = message.manifest, .output = message.output, .cache = message.cache, .partitions = message.partitions },
    };
}

pub fn send(allocator: std.mem.Allocator, writer: *std.Io.Writer, identity: Identity, cwd: []const u8, request: Request) !void {
    if (comptime !generated) return seed.send(writer, identity, cwd, request);

    const rule = @import("generated_resident_send");

    const input: std.meta.Child(rule.Input) = .{
        .size = identity.size,
        .mtime_low = identity.mtime_low,
        .mtime_high = identity.mtime_high,
        .path = identity.path,
        .cwd = cwd,
        .manifest = request.manifest,
        .output = request.output,
        .cache = request.cache,
        .partitions = request.partitions,
    };

    var buffer: [2048]u8 = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(backing.allocator());

    defer arena.deinit();

    const payload = try rule.executeIn(arena.allocator(), &input);

    try writer.writeAll(payload);
}

pub fn admit(own: *const Identity, message: *const Envelope, here: []const u8) Status {
    if (comptime !generated) return seed.admit(own, message, here);

    const rule = @import("generated_resident_admit");
    const Input = std.meta.Child(rule.Input);
    const Peer = std.meta.Child(@FieldType(Input, "own"));
    const expected = zx.columns.view(Peer, own);
    const caller = zx.columns.view(Peer, &message.caller);
    const input: Input = .{ .own = &expected, .caller = &caller, .cwd = message.cwd, .here = here };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const status = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return @fromBackingInt(@intCast(@backingInt(status)));
}

pub fn reply(allocator: std.mem.Allocator, writer: *std.Io.Writer, status: Status, summary: []const u8) !void {
    if (comptime !generated) return seed.reply(writer, status, summary);

    const rule = @import("generated_resident_reply");
    const input: std.meta.Child(rule.Input) = .{ .status = @fromBackingInt(@intCast(@backingInt(status))), .summary = summary };
    var buffer: [512]u8 = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(backing.allocator());

    defer arena.deinit();

    const payload = try rule.executeIn(arena.allocator(), &input);

    try writer.writeAll(payload);
}

pub fn readSummary(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]const u8 {
    if (comptime !generated) return seed.summary(allocator, reader);

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const code = try reader.takeByte();
    const frame = try @import("generated_resident_summary").executeValue(empty.allocator(), code);

    if (!frame.known) return null;
    if (frame.accepted) return try readText(allocator, reader);
    try reader.discardAll(try reader.takeInt(u32, .little));

    return null;
}

fn readText(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]const u8 {
    return reader.readAlloc(allocator, try reader.takeInt(u32, .little));
}

pub fn expired(last: u64, now: u64) bool {
    if (comptime !generated) return now >= last and now - last >= seed.idle_nanoseconds;

    const rule = @import("generated_resident_expired");
    const input: std.meta.Child(rule.Input) = .{ .last = last, .now = now };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}
