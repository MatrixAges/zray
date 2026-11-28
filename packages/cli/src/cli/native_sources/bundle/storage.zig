const std = @import("std");
const collect = @import("../collect.zig");
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;
const PreparedBundle = @import("native_resource_abi").layouts.@"zig:native_resource_host".PreparedBundle;

pub fn prepareBundle(allocator: std.mem.Allocator, handle: *anyopaque) (Error || std.mem.Allocator.Error)!*const PreparedBundle {
    const self = Context.get(handle);

    self.entry = if (self.options.path) |path|
        std.fs.path.resolve(self.allocator, &.{ self.project_root, path }) catch |err| return self.fail(err)

    else
        null;

    self.root = if (self.entry) |entry|
        std.fs.path.dirname(entry).?

    else
        std.fs.path.resolve(self.allocator, &.{self.project_root}) catch |err| return self.fail(err);

    const output = std.fs.path.resolve(allocator, &.{self.directory}) catch |err| return self.fail(err);

    const physical = std.Io.Dir.cwd().realPathFileAlloc(self.io, output, allocator) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return self.fail(err),
    };

    const prepared = try allocator.create(PreparedBundle);

    prepared.* = .{ .entry = self.entry, .output = output, .physical_output = physical };

    return prepared;
}

pub fn bundlePath(handle: *anyopaque, path: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return collect.referencedPath(self.allocator, self.root, self.root, path) catch |err| return self.fail(err);
}

pub fn observePhysicalResource(allocator: std.mem.Allocator, handle: *anyopaque, resource: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    if (self.inputs) |inputs| inputs.add(self.io, resource) catch |err| return self.fail(err);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, resource, allocator) catch |err| self.fail(err);
}

pub fn prepareIncludes(handle: *anyopaque) Error![]const u8 {
    const self = Context.get(handle);

    self.destination = std.fs.path.join(self.allocator, &.{ "native", self.options.name, "source" }) catch |err| return self.fail(err);
    self.include_paths = self.allocator.alloc([]const u8, self.options.include_paths.len) catch |err| return self.fail(err);

    return self.destination;
}
