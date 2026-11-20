const std = @import("std");
const Options = @import("../options.zig").Options;
const Self = @This();

directory: []const u8,
binary: []const u8,
assembly: ?[]const u8,
pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !Self {
    if (options.assembly) |path| {
        const binary = try std.fs.path.resolve(allocator, &.{options.output.?});
        const assembly = try std.fs.path.resolve(allocator, &.{path});

        if (std.mem.eql(u8, binary, assembly)) return error.ConflictingOutputPaths;
    }

    var random: [16]u8 = undefined;

    std.Io.random(io, &random);

    const directory = try std.fmt.allocPrint(allocator, ".zxc/build/pending/{s}", .{std.fmt.bytesToHex(random, .lower)});

    try std.Io.Dir.cwd().createDirPath(io, ".zxc/build/pending");
    try std.Io.Dir.cwd().createDir(io, directory, .default_dir);

    errdefer std.Io.Dir.cwd().deleteTree(io, directory) catch {};

    return .{
        .directory = directory,
        .binary = try std.fs.path.join(allocator, &.{ directory, "binary", std.fs.path.basename(options.output.?) }),
        .assembly = if (options.assembly) |path| try std.fs.path.join(allocator, &.{ directory, "assembly", std.fs.path.basename(path) }) else null,
    };
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

    const published = @import("cli_source").publish_staged.executeIn(allocator, &.{
        .publication = @ptrCast(&publication),
        .directory = @ptrCast(&cursor),
        .primary = std.fs.path.basename(self.binary),
        .assembly = self.assembly != null,
    }) catch |err| return failure.unwrap(err);

    if (!published) return error.UnsupportedBuildArtifact;
}
