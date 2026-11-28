const std = @import("std");
const resources = @import("publication_host").resources;
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn includeFiles(handle: *const anyopaque, root: []const u8, absolute: []const u8) Error![]const []const u8 {
    const self = Context.get(handle);
    const files = resources.files(self.io, self.allocator, absolute, self.inputs) catch |err| return self.fail(err);
    const relatives = self.allocator.alloc([]const u8, files.len) catch |err| return self.fail(err);

    for (files, 0..) |path, index| {
        relatives[index] = std.fs.path.relativeAlloc(self.allocator, root, null, root, path) catch |err| return self.fail(err);
    }

    return relatives;
}
