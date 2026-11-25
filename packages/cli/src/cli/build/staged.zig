const std = @import("std");
const Options = @import("../options.zig").Options;
const Self = @This();
const source = @import("cli_source");
const constants = source.staged_output_constants.@"zx.constants";

directory: []const u8,
binary: []const u8,
assembly: ?[]const u8,
pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !Self {
    var random: [16]u8 = undefined;

    std.Io.random(io, &random);

    const nonce = std.fmt.bytesToHex(random, .lower);

    const files = (try source.place_staged_output.executeValue(allocator, &.{
        .binary = options.output.?,
        .assembly = options.assembly,
        .separator = &.{std.fs.path.sep},
        .nonce = &nonce,
    })) orelse return error.ConflictingOutputPaths;

    try std.Io.Dir.cwd().createDirPath(io, constants.pending_directory);
    try std.Io.Dir.cwd().createDir(io, files.directory, .default_dir);

    return .{ .directory = files.directory, .binary = files.binary, .assembly = files.assembly };
}

pub fn deinit(self: Self, io: std.Io) void {
    std.Io.Dir.cwd().deleteTree(io, self.directory) catch {};
}

pub fn publish(self: Self, io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    const host = @import("publication_host");
    var failure: host.Failure = .{};

    var publication: host.application = .{
        .io = io,
        .allocator = allocator,
        .failure = &failure,
        .binary = .{ .source = self.binary, .destination = options.output },
        .assembly = .{ .source = self.assembly, .destination = options.assembly },
    };

    var directory: host.directory = .{
        .io = io,
        .allocator = allocator,
        .failure = &failure,
        .source = std.fs.path.dirname(self.binary).?,
        .destination = std.fs.path.dirname(options.output.?) orelse ".",
    };

    defer directory.deinit();

    const cursor = &directory;

    const published = source.publish_staged.executeIn(allocator, &.{
        .publication = @ptrCast(&publication),
        .directory = @ptrCast(&cursor),
        .primary = std.fs.path.basename(self.binary),
        .assembly = self.assembly != null,
    }) catch |err| return failure.unwrap(err);

    if (!published) return error.UnsupportedBuildArtifact;
}
