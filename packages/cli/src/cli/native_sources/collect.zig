const std = @import("std");
const resources = @import("publication_host").resources;
const storage = @import("storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn openCollection(handle: *const anyopaque, root: []const u8, entry: ?[]const u8) Error![]const u8 {
    const self = Context.get(handle);

    if (entry) |path| if (self.inputs) |inputs| inputs.add(self.io, path) catch |err| return self.fail(err);

    return std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator) catch |err| return self.fail(err);
}

pub fn readBundle(handle: *const anyopaque, absolute: []const u8) Error![]const []const u8 {
    const self = Context.get(handle);

    return resources.files(self.io, self.allocator, absolute, self.inputs) catch |err| return self.fail(err);
}

pub fn readPending(handle: *const anyopaque, path: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.allocator, .unlimited, .of(u8), 0) catch |err| self.fail(err);
}

pub fn observePending(handle: *const anyopaque, path: []const u8, content: []const u8) Error!void {
    const self = Context.get(handle);

    if (self.inputs) |inputs| inputs.record(self.io, path, content) catch |err| return self.fail(err);
}
