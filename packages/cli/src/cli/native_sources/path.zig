const std = @import("std");
const rules = @import("cli_source");

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
