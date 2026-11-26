const std = @import("std");
const artifacts = @import("artifact_io");
const paths = @import("publication_host").paths;
const collect = @import("../collect.zig");
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn prepareBundle(handle: *anyopaque) Error!?[]const u8 {
    const self = Context.get(handle);

    self.entry = if (self.options.path) |path|
        std.fs.path.resolve(self.allocator, &.{ self.project_root, path }) catch |err| return self.fail(err)

    else
        null;

    self.root = if (self.entry) |entry|
        std.fs.path.dirname(entry).?

    else
        std.fs.path.resolve(self.allocator, &.{self.project_root}) catch |err| return self.fail(err);

    self.output_root = std.fs.path.resolve(self.allocator, &.{self.directory}) catch |err| return self.fail(err);

    self.physical_output = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.output_root, self.allocator) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return self.fail(err),
    };

    return self.entry;
}

pub fn bundlePath(handle: *anyopaque, path: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return collect.referencedPath(self.allocator, self.root, self.root, path) catch |err| return self.fail(err);
}

pub fn logicalOutputInside(handle: *anyopaque, resource: []const u8) Error!bool {
    const self = Context.get(handle);

    return outputInside(self.allocator, resource, self.output_root) catch |err| return self.fail(err);
}

pub fn physicalOutputInside(handle: *anyopaque, resource: []const u8) Error!bool {
    const self = Context.get(handle);
    const output = self.physical_output orelse return false;

    if (self.inputs) |inputs| inputs.add(self.io, resource) catch |err| return self.fail(err);

    const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, resource, self.allocator) catch |err| return self.fail(err);

    return outputInside(self.allocator, canonical, output) catch |err| return self.fail(err);
}

fn outputInside(allocator: std.mem.Allocator, resource: []const u8, output: []const u8) !bool {
    const relative = try std.fs.path.relative(allocator, resource, null, resource, output);

    return paths.within(relative);
}

pub fn prepareIncludes(handle: *anyopaque) Error!void {
    const self = Context.get(handle);

    self.destination = std.fs.path.join(self.allocator, &.{ "native", self.options.name, "source" }) catch |err| return self.fail(err);
    self.include_paths = self.allocator.alloc([]const u8, self.options.include_paths.len) catch |err| return self.fail(err);
}

pub fn prepareFiles(handle: *anyopaque) Error!void {
    const self = Context.get(handle);

    self.files = self.allocator.alloc(storage.File, self.sources.items.len) catch |err| return self.fail(err);
}

pub fn publishFile(handle: *anyopaque, index: u64) Error!void {
    const self = Context.get(handle);
    const source = self.sources.items[@intCast(index)];

    publish(self, @intCast(index), source) catch |err| return self.fail(err);
}

fn publish(self: *Context, index: usize, source: storage.Source) !void {
    const allocator = self.allocator;
    const target = try std.fs.path.join(allocator, &.{ self.destination, source.path });
    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(source.bytes, &digest, .{});

    const hex = std.fmt.bytesToHex(digest, .lower);

    try artifacts.write(self.io, try std.fs.path.join(allocator, &.{ self.directory, target }), source.bytes);

    self.files[index] = .{
        .path = target,
        .kind = source.kind,
        .sha256 = try allocator.dupe(u8, &hex),
        .referenced_from = if (source.referenced_from) |path| try std.fs.path.join(allocator, &.{ self.destination, path }) else null,
    };
}
