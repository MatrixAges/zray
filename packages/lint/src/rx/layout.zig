const std = @import("std");
const dsl = @import("dsl");
const NodeView = @import("node_view.zig");
const rule = @import("lint_rx");
const root = @import("root.zig");
const width = @import("../layout/root.zig").use_default_width;

pub fn format(allocator: std.mem.Allocator, source: []const u8, node: dsl.ast.Node) std.mem.Allocator.Error![]u8 {
    return formatView(allocator, source, NodeView{ .node = node });
}

pub fn formatView(allocator: std.mem.Allocator, source: []const u8, node: anytype) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const planned = try rule.run(temporary, 1, source, width, node);

    return root.applyEdits(allocator, temporary, source, planned, false);
}
