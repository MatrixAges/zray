const std = @import("std");
const archive = @import("../archive.zig");
const constants = @import("cli_source").store_constants.@"zx.constants";
pub const storage = @import("receipt/storage.zig");

pub const Receipt = struct {
    format_version: u32 = constants.receipt_version,
    archive_sha256: []const u8,
    files: []const archive.File,
};

pub fn verify(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, expected: []const u8) !void {
    var state: storage.State = .{ .io = io, .allocator = allocator, .directory = directory };

    defer state.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const cursor = &state;

    const status = @import("cli_source").receipt.executeIn(scratch.allocator(), &.{
        .receipt = @ptrCast(&cursor),
        .expected = expected,
    }) catch |err| switch (err) {
        error.ReceiptHostFailure => return state.failure.?,
        else => |failure| return failure,
    };

    switch (status) {
        .Valid => {},
        inline else => |reason| return @field(anyerror, @tagName(reason)),
    }
}
