const std = @import("std");
const package_name = @import("pkgs_source").package_name;
pub const Index = @import("index.zig");
pub const Lock = @import("lock.zig");
pub const version = @import("version.zig");
pub const workspace = @import("workspace.zig");
pub const graph = @import("graph.zig");
pub const install = @import("install.zig");

pub fn validName(name: []const u8) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return package_name.executeIn(empty.allocator(), name) catch unreachable;
}
