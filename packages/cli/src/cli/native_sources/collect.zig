const std = @import("std");
const paths = @import("publication_host").paths;
const resources = @import("publication_host").resources;
const storage = @import("storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn openCollection(handle: *anyopaque) Error!void {
    const self = Context.get(handle);

    if (self.entry) |path| if (self.inputs) |inputs| inputs.add(self.io, path) catch |err| return self.fail(err);

    self.canonical_root = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.root, self.allocator) catch |err| return self.fail(err);
}

pub fn readBundle(handle: *anyopaque, path: []const u8) Error![]const []const u8 {
    const self = Context.get(handle);
    const absolute = referencedPath(self.allocator, self.root, self.root, path) catch |err| return self.fail(err);

    checkPhysical(self, absolute) catch |err| return self.fail(err);

    return resources.files(self.io, self.allocator, absolute, self.inputs) catch |err| return self.fail(err);
}

pub fn relativePath(handle: *anyopaque, path: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return withinRelativePath(self.allocator, self.root, path) catch |err| return self.fail(err);
}

pub fn resolveReference(handle: *anyopaque, current_path: []const u8, reference_path: []const u8) Error![]const u8 {
    const self = Context.get(handle);
    const parent = std.fs.path.dirname(current_path).?;

    return referencedPath(self.allocator, self.root, parent, reference_path) catch |err| return self.fail(err);
}

pub fn checkPending(handle: *anyopaque, path: []const u8) Error!void {
    const self = Context.get(handle);

    checkPhysical(self, path) catch |err| return self.fail(err);
}

fn checkPhysical(self: *Context, path: []const u8) !void {
    if (self.inputs) |inputs| try inputs.add(self.io, path);

    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);

    _ = try withinRelativePath(self.allocator, self.canonical_root, canonical);
}

pub fn readPending(handle: *anyopaque, path: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.allocator, .unlimited, .of(u8), 0) catch |err| self.fail(err);
}

pub fn observePending(handle: *anyopaque, path: []const u8, content: []const u8) Error!void {
    const self = Context.get(handle);

    if (self.inputs) |inputs| inputs.record(self.io, path, content) catch |err| return self.fail(err);
}

pub fn referencedPath(allocator: std.mem.Allocator, root: []const u8, parent: []const u8, path: []const u8) ![]const u8 {
    if (!paths.validReference(path)) return error.InvalidNativeResourcePath;

    const absolute = try std.fs.path.resolve(allocator, &.{ parent, path });

    _ = try withinRelativePath(allocator, root, absolute);

    return absolute;
}

fn withinRelativePath(allocator: std.mem.Allocator, root: []const u8, absolute: []const u8) ![]const u8 {
    const relative = try std.fs.path.relative(allocator, root, null, root, absolute);

    if (!paths.within(relative)) return error.NativeResourceOutsideModule;

    return relative;
}
