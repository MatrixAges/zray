const std = @import("std");
const collect = @import("../collect.zig");
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn physicalOutput(allocator: std.mem.Allocator, handle: *const anyopaque, output: []const u8) Error!?[]const u8 {
    const self = Context.get(handle);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, output, allocator) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return self.fail(err),
    };
}

pub fn bundlePath(handle: *const anyopaque, root: []const u8, path: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return collect.referencedPath(self.allocator, root, root, path) catch |err| return self.fail(err);
}

pub fn observePhysicalResource(allocator: std.mem.Allocator, handle: *const anyopaque, resource: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    if (self.inputs) |inputs| inputs.add(self.io, resource) catch |err| return self.fail(err);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, resource, allocator) catch |err| self.fail(err);
}
