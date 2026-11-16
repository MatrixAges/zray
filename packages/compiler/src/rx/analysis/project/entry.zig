const std = @import("std");
const generated = @import("rx_options").generated_graph;

pub fn isZX(path: []const u8) bool {
    if (comptime generated) {
        const rule = @import("generated_rx_project_entry_kind");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeValue(empty.allocator(), path) catch unreachable;
    }

    return std.mem.endsWith(u8, path, ".zx");
}

pub fn lookup(path: []const u8, modules: []const []const u8) ?usize {
    if (comptime generated) {
        const rule = @import("generated_rx_project_entry_lookup");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const row = rule.executeValue(empty.allocator(), &.{ .path = path, .modules = modules }) catch unreachable;

        return if (row) |index| @intCast(index) else null;
    }

    for (modules, 0..) |source, index| {
        if (std.mem.eql(u8, source, path)) return index;
    }

    return null;
}
