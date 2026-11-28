const std = @import("std");
const paths = @import("publication_host").paths;
const resources = @import("publication_host").resources;
const storage = @import("storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn openCollection(handle: *const anyopaque, root: []const u8, entry: ?[]const u8) Error![]const u8 {
    const self = Context.get(handle);

    if (entry) |path| if (self.inputs) |inputs| inputs.add(self.io, path) catch |err| return self.fail(err);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator) catch |err| return self.fail(err);
}

pub fn readBundle(handle: *const anyopaque, canonical_root: []const u8, absolute: []const u8) Error![]const []const u8 {
    const self = Context.get(handle);

    checkPhysical(self, canonical_root, absolute) catch |err| return self.fail(err);

    return resources.files(self.io, self.allocator, absolute, self.inputs) catch |err| return self.fail(err);
}

pub fn checkPending(handle: *const anyopaque, canonical_root: []const u8, path: []const u8) Error!void {
    const self = Context.get(handle);

    checkPhysical(self, canonical_root, path) catch |err| return self.fail(err);
}

fn checkPhysical(self: *Context, canonical_root: []const u8, path: []const u8) !void {
    if (self.inputs) |inputs| try inputs.add(self.io, path);

    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);

    _ = try withinRelativePath(self.allocator, canonical_root, canonical);
}

pub fn readPending(handle: *const anyopaque, path: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.allocator, .unlimited, .of(u8), 0) catch |err| self.fail(err);
}

pub fn observePending(handle: *const anyopaque, path: []const u8, content: []const u8) Error!void {
    const self = Context.get(handle);

    if (self.inputs) |inputs| inputs.record(self.io, path, content) catch |err| return self.fail(err);
}

fn withinRelativePath(allocator: std.mem.Allocator, root: []const u8, absolute: []const u8) ![]const u8 {
    const relative = try std.fs.path.relative(allocator, root, null, root, absolute);

    if (!paths.within(relative)) return error.NativeResourceOutsideModule;

    return relative;
}
