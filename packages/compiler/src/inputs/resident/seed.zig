const std = @import("std");
const protocol = @import("../resident.zig");

pub const serve_command = "--serve";
pub const socket_name = "generator.sock";
pub const enabled_name = "ZXC_RESIDENT_GENERATOR";
pub const memory_name = "ZXC_RESIDENT_MEMORY";
pub const disabled_value = "0";
pub const memory_value = "1";
pub const idle_nanoseconds: u64 = 15 * std.time.ns_per_min;
pub const check_interval_seconds: u64 = 30;
pub const reply_timeout_seconds: u64 = 120;

pub fn command(args: []const [:0]const u8) protocol.Command {
    if (args.len < 2) return .Missing;

    const name = args[1];

    if (std.mem.eql(u8, name, "--lexer")) return if (args.len == 5) .Lexer else .Incomplete;
    if (std.mem.eql(u8, name, "--standard-abi")) return if (args.len == 3) .StandardAbi else .Incomplete;

    if (std.mem.eql(u8, name, "--manifest")) {
        if (args.len == 5) return .Manifest;
        if (args.len == 7 and std.mem.eql(u8, args[5], "--partitions")) return .Partitioned;

        return .Incomplete;
    }

    if (std.mem.eql(u8, name, serve_command)) return switch (args.len) {
        3 => .Serve,
        6 => .Warm,
        else => .Incomplete,
    };

    return .Unknown;
}

pub fn receive(allocator: std.mem.Allocator, reader: *std.Io.Reader) !protocol.Envelope {
    const caller: protocol.Identity = .{
        .size = try reader.takeInt(u64, .little),
        .mtime_low = try reader.takeInt(u64, .little),
        .mtime_high = try reader.takeInt(u64, .little),
        .path = try text(reader, allocator),
    };

    const cwd = try text(reader, allocator);

    const request: protocol.Request = .{
        .manifest = try text(reader, allocator),
        .output = try text(reader, allocator),
        .cache = try text(reader, allocator),
        .partitions = try reader.takeInt(u32, .little),
    };

    return .{ .caller = caller, .cwd = cwd, .request = request };
}

pub fn send(writer: *std.Io.Writer, identity: protocol.Identity, cwd: []const u8, request: protocol.Request) !void {
    try writer.writeInt(u64, identity.size, .little);
    try writer.writeInt(u64, identity.mtime_low, .little);
    try writer.writeInt(u64, identity.mtime_high, .little);
    for ([_][]const u8{ identity.path, cwd, request.manifest, request.output, request.cache }) |value| try field(writer, value);
    try writer.writeInt(u32, request.partitions, .little);
}

pub fn admit(own: *const protocol.Identity, message: *const protocol.Envelope, here: []const u8) protocol.Status {
    const caller = &message.caller;

    if (own.size != caller.size or own.mtime_low != caller.mtime_low or own.mtime_high != caller.mtime_high or !std.mem.eql(u8, own.path, caller.path)) return .Stale;

    return if (std.mem.eql(u8, message.cwd, here)) .Done else .Declined;
}

pub fn reply(writer: *std.Io.Writer, status: protocol.Status, result: []const u8) !void {
    try writer.writeByte(@backingInt(status));
    try field(writer, result);
}

pub fn summary(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]const u8 {
    const status = std.enums.fromInt(protocol.Status, try reader.takeByte()) orelse return null;
    const result = try text(reader, allocator);

    return if (status == .Done) result else null;
}

fn field(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeInt(u32, @intCast(value.len), .little);
    try writer.writeAll(value);
}

fn text(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]const u8 {
    const length = try reader.takeInt(u32, .little);

    return reader.readAlloc(allocator, length);
}
