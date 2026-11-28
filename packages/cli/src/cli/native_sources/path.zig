const std = @import("std");
const rules = @import("cli_source");

pub fn relativePathFrom(allocator: std.mem.Allocator, base: []const u8, target: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fs.path.relativeAlloc(allocator, base, null, base, target);
}

pub fn validReference(path: []const u8) bool {
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return rules.native_resource_path.executeValue(memory.allocator(), &.{
        .path = path,
        .absolute = std.fs.path.isAbsolute(path),
    }) catch unreachable;
}

pub fn within(path: []const u8) bool {
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return rules.native_resource_within.executeIn(memory.allocator(), &.{
        .path = path,
        .absolute = std.fs.path.isAbsolute(path),
        .separator = std.fs.path.sep,
    }) catch unreachable;
}
