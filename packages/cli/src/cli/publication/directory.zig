const std = @import("std");
const effects = @import("effects.zig");
const constants = @import("cli_source").publication_constants.@"zx.constants";
const Self = @This();

io: std.Io,
allocator: std.mem.Allocator,
failure: *effects.Failure,
source: []const u8,
destination: []const u8 = &.{},

opened: bool = false,
directory: std.Io.Dir = undefined,
walker: std.Io.Dir.Walker = undefined,
path: []const u8 = &.{},
pub fn deinit(self: *Self) void {
    if (!self.opened) return;

    while (self.walker.inner.stack.items.len != 0) self.walker.leave(self.io);

    self.walker.deinit();
    self.directory.close(self.io);
}

pub fn openDirectory(handle: *const anyopaque) effects.Error!void {
    return effects.state(Self, handle).open(true);
}

pub fn open(self: *Self, follow_symlinks: bool) effects.Error!void {
    self.directory = std.Io.Dir.cwd().openDir(self.io, self.source, .{ .iterate = true, .follow_symlinks = follow_symlinks }) catch |err| return self.failure.save(err);

    errdefer self.directory.close(self.io);

    self.walker = self.directory.walk(self.allocator) catch |err| return self.failure.save(err);
    self.opened = true;
}

pub fn advance(self: *Self) effects.Error!?std.Io.File.Kind {
    // The macOS arm64 ReleaseSmall build can hoist the path-buffer pointer
    // across its initial allocation when the walker is inlined here.
    const item = (@call(.never_inline, std.Io.Dir.Walker.next, .{ &self.walker, self.io }) catch |err| return self.failure.save(err)) orelse return null;

    self.path = item.path;

    return item.kind;
}

pub fn nextEntry(handle: *const anyopaque, name: []const u8) effects.Error!u8 {
    return effects.state(Self, handle).nextNamed(name);
}

pub fn nextNamed(self: *Self, name: []const u8) effects.Error!u8 {
    const kind = (try self.advance()) orelse return constants.end_of_directory;
    const named = std.mem.eql(u8, self.path, name);

    return switch (kind) {
        .directory => constants.directory_entry,
        .file => if (named) constants.named_regular_entry else constants.regular_entry,
        else => if (named) constants.named_other_entry else constants.other_entry,
    };
}

pub fn copyEntry(handle: *const anyopaque) effects.Error!void {
    const self = effects.state(Self, handle);
    const target = std.fs.path.join(self.allocator, &.{ self.destination, self.path }) catch |err| return self.failure.save(err);

    defer self.allocator.free(target);

    return self.copy(self.path, target);
}

pub fn copy(self: *Self, relative: []const u8, target: []const u8) effects.Error!void {
    self.directory.copyFile(relative, .cwd(), target, self.io, .{ .make_path = true }) catch |err| return self.failure.save(err);
}
