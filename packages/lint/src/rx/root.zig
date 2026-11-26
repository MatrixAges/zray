const std = @import("std");
const dsl = @import("dsl");
const rule = @import("lint_rx");
pub const structure = @import("layout.zig").format;
pub const structureView = @import("layout.zig").formatView;
pub const NodeView = @import("node_view.zig");

pub fn format(allocator: std.mem.Allocator, source: []const u8, node: dsl.ast.Node) std.mem.Allocator.Error![]u8 {
    return formatView(allocator, source, NodeView{ .node = node });
}

pub fn formatView(allocator: std.mem.Allocator, source: []const u8, node: anytype) std.mem.Allocator.Error![]u8 {
    return rule.run(allocator, 0, source, 0, node);
}
