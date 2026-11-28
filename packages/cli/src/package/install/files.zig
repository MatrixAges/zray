const std = @import("std");
const Lock = @import("pkgs").Lock;
const Inputs = @import("watch_inputs").Inputs;
pub const Loaded = struct { lock: Lock, source: []const u8 };
pub const Installation = struct { format_version: u32, lock_sha256: []const u8, paths: []const []const u8 };
pub const maximum_bytes = 32 * 1024 * 1024;

pub fn load(io: std.Io, allocator: std.mem.Allocator, root: []const u8, inputs: ?*Inputs) !?Loaded {
    const path = try std.fs.path.join(allocator, &.{ root, "pkg.lock.json" });

    const source = read(io, allocator, path, inputs) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const parsed = try Lock.parse(allocator, source);

    return .{ .lock = parsed.value, .source = source };
}

pub const Mapping = struct { expected: [64]u8, value: Installation };

pub fn readMapping(io: std.Io, allocator: std.mem.Allocator, root: []const u8, loaded: Loaded, inputs: ?*Inputs) !?Mapping {
    const digest = hash(loaded.source);
    const path = try mapPath(allocator, root, &digest);

    const source = read(io, allocator, path, inputs) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const data = try std.json.parseFromSliceLeaky(Installation, allocator, source, .{});

    return .{ .expected = digest, .value = data };
}

pub const Publication = struct {
    lock: []const u8,
    mapping: []const u8,
    digest: [64]u8,
};

pub fn render(allocator: std.mem.Allocator, prepared: @import("model.zig").Prepared) !Publication {
    const source = prepared.source orelse try std.json.Stringify.valueAlloc(allocator, prepared.lock, .{ .whitespace = .indent_2 });
    const digest = hash(source);
    const mapping = try std.json.Stringify.valueAlloc(allocator, Installation{ .format_version = @import("cli_source").graph_constants.@"zx.constants".mapping_version, .lock_sha256 = &digest, .paths = prepared.paths }, .{ .whitespace = .indent_2 });

    return .{ .lock = source, .mapping = mapping, .digest = digest };
}

fn mapPath(allocator: std.mem.Allocator, root: []const u8, digest: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root, ".zxc", "packages", try std.fmt.allocPrint(allocator, "{s}.json", .{digest}) });
}

fn hash(source: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inputs: ?*Inputs) ![]const u8 {
    if (inputs) |observed| try observed.add(io, path);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(maximum_bytes));

    if (inputs) |observed| try observed.record(io, path, source);

    return source;
}
