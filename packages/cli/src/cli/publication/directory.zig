const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const abi = @import("publication_abi");
const effects = @import("effects.zig");
const ResourceEntry = abi.layouts.@"zig:publication_host".ResourceEntry;
const Kind = abi.native.@"zig:publication_host".ResourceKind;
const Resource = abi.native.@"zig:publication_host".ResourceEntry;
const Self = @This();

io: std.Io,
allocator: std.mem.Allocator,
failure: *effects.Failure,
source: []const u8,
inputs: ?*Inputs = null,
opened: bool = false,
directory: std.Io.Dir = undefined,
walker: std.Io.Dir.Walker = undefined,
path: []const u8 = &.{},

resource_view: ResourceEntry = undefined,
pub fn deinit(self: *Self) void {
    if (!self.opened) return;

    while (self.walker.inner.stack.items.len != 0) self.walker.leave(self.io);

    self.walker.deinit();
    self.directory.close(self.io);
}

pub fn copyPublishedFile(io: std.Io, source: []const u8, destination: []const u8) std.Io.Dir.CopyFileError!void {
    return std.Io.Dir.cwd().copyFile(source, .cwd(), destination, io, .{ .make_path = true });
}

pub fn listPublicationDirectory(allocator: std.mem.Allocator, io: std.Io, source: []const u8) ![]const Resource {
    const directory = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });

    defer directory.close(io);

    var walker = try directory.walk(allocator);

    defer walker.deinit();
    defer while (walker.inner.stack.items.len != 0) walker.leave(io);

    var rows: std.ArrayList(Resource) = .empty;

    while (try nextWalkEntry(&walker, io)) |item| {
        const row = try allocator.create(ResourceEntry);

        row.* = .{ .kind = resourceKind(item.kind), .path = try allocator.dupe(u8, item.path) };

        try rows.append(allocator, row);
    }

    return rows.toOwnedSlice(allocator);
}

pub fn resourceKind(kind: std.Io.File.Kind) Kind {
    return switch (kind) {
        .file => .Regular,
        .directory => .Directory,
        .sym_link => .Symlink,
        else => .Other,
    };
}

pub fn openDirectory(handle: *const anyopaque, follow_symlinks: bool) effects.Error!void {
    const self = effects.state(Self, handle);

    if (self.inputs) |observed| observed.addDirectory(self.io, self.source) catch |err| return self.failure.save(err);

    return self.open(follow_symlinks);
}

pub fn open(self: *Self, follow_symlinks: bool) effects.Error!void {
    self.directory = std.Io.Dir.cwd().openDir(self.io, self.source, .{ .iterate = true, .follow_symlinks = follow_symlinks }) catch |err| return self.failure.save(err);

    errdefer self.directory.close(self.io);

    self.walker = self.directory.walk(self.allocator) catch |err| return self.failure.save(err);
    self.opened = true;
}

pub fn advance(self: *Self) effects.Error!?std.Io.File.Kind {
    const item = (nextWalkEntry(&self.walker, self.io) catch |err| return self.failure.save(err)) orelse return null;

    self.path = item.path;

    return item.kind;
}

fn nextWalkEntry(walker: *std.Io.Dir.Walker, io: std.Io) !?std.Io.Dir.Walker.Entry {
    // The macOS arm64 ReleaseSmall build can hoist the path-buffer pointer
    // across its initial allocation when the walker is inlined here.
    return @call(.never_inline, std.Io.Dir.Walker.next, .{ walker, io });
}

pub fn nextEntry(handle: *const anyopaque) effects.Error!*const ResourceEntry {
    const self = effects.state(Self, handle);

    self.resource_view = if (try self.advance()) |kind|
        .{ .kind = resourceKind(kind), .path = self.path }

    else
        .{ .kind = .End, .path = "" };

    return &self.resource_view;
}

pub fn copyDirectoryFile(handle: *const anyopaque, relative: []const u8, target: []const u8) effects.Error!void {
    const self = effects.state(Self, handle);

    self.directory.copyFile(relative, .cwd(), target, self.io, .{ .make_path = true }) catch |err| return self.failure.save(err);
}

pub fn removeRetiredFile(io: std.Io, target: []const u8) std.Io.Dir.DeleteFileError!void {
    std.Io.Dir.cwd().deleteFile(io, target) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
