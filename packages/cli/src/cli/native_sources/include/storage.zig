const std = @import("std");
const paths = @import("publication_host").paths;
const resources = @import("publication_host").resources;
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;
const IncludeTarget = @import("native_resource_abi").layouts.@"zig:native_resource_host".IncludeTarget;

pub fn selectInclude(handle: *anyopaque, path: []const u8) Error!*const IncludeTarget {
    const self = Context.get(handle);
    const allocator = self.allocator;
    const absolute = std.fs.path.resolve(allocator, &.{ self.project_root, path }) catch |err| return self.fail(err);
    const relative = std.fs.path.relative(allocator, self.root, null, self.root, absolute) catch |err| return self.fail(err);

    self.include_target = .{
        .absolute = absolute,
        .relative = relative,
        .within = paths.within(relative),
    };

    return &self.include_target;
}

pub fn includeFiles(handle: *anyopaque, absolute: []const u8) Error![]const []const u8 {
    const self = Context.get(handle);
    const files = resources.files(self.io, self.allocator, absolute, self.inputs) catch |err| return self.fail(err);
    const relatives = self.allocator.alloc([]const u8, files.len) catch |err| return self.fail(err);

    for (files, 0..) |path, index| {
        relatives[index] = std.fs.path.relative(self.allocator, self.root, null, self.root, path) catch |err| return self.fail(err);
    }

    return relatives;
}

pub fn writeInclude(handle: *anyopaque, index: u64, bundled: bool, absolute: []const u8, relative: []const u8) Error!void {
    const self = Context.get(handle);

    if (!bundled) {
        self.include_paths[@intCast(index)] = absolute;

        return;
    }

    const path = std.fs.path.join(self.allocator, &.{ self.destination, relative }) catch |err| return self.fail(err);

    self.include_paths[@intCast(index)] = path;

    self.relocations.append(self.allocator, .{
        .source = relative,
        .destination = path,
    }) catch |err| return self.fail(err);
}
