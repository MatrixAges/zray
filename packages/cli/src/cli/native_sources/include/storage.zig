const std = @import("std");
const paths = @import("publication_host").paths;
const resources = @import("../resources.zig");
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn selectInclude(handle: *const anyopaque, path: []const u8) Error!?[]const u8 {
    const self = Context.get(handle);
    const allocator = self.allocator;

    self.include_absolute = std.fs.path.resolve(allocator, &.{ self.project_root, path }) catch |err| return self.fail(err);
    self.include_relative = std.fs.path.relative(allocator, self.root, null, self.root, self.include_absolute) catch |err| return self.fail(err);

    return if (paths.within(self.include_relative)) self.include_relative else null;
}

pub fn includeFiles(handle: *const anyopaque) Error![]const []const u8 {
    const self = Context.get(handle);

    return resources.files(self.io, self.allocator, self.include_absolute, self.inputs) catch |err| return self.fail(err);
}

pub fn includesFile(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = Context.get(handle);
    const relative = std.fs.path.relative(self.allocator, self.root, null, self.root, path) catch |err| return self.fail(err);

    return self.seen.contains(relative);
}

pub fn writeInclude(handle: *const anyopaque, index: u64, bundled: bool) Error!void {
    const self = Context.get(handle);

    if (!bundled) {
        self.include_paths[@intCast(index)] = self.include_absolute;

        return;
    }

    const path = std.fs.path.join(self.allocator, &.{ self.destination, self.include_relative }) catch |err| return self.fail(err);

    self.include_paths[@intCast(index)] = path;

    self.relocations.append(self.allocator, .{
        .source = self.include_relative,
        .destination = path,
    }) catch |err| return self.fail(err);
}
