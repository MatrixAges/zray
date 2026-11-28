const std = @import("std");
const dsl = @import("dsl");
const rule = @import("lint_rx");
pub const NodeView = @import("node_view.zig");
const width = @import("../layout/root.zig").use_default_width;

pub fn format(allocator: std.mem.Allocator, source: []const u8, node: dsl.ast.Node) std.mem.Allocator.Error![]u8 {
    return formatView(allocator, source, NodeView{ .node = node });
}

pub fn formatView(allocator: std.mem.Allocator, source: []const u8, node: anytype) std.mem.Allocator.Error![]u8 {
    return rule.run(allocator, .Structure, source, width, node);
}

pub fn structure(allocator: std.mem.Allocator, source: []const u8, node: dsl.ast.Node) std.mem.Allocator.Error![]u8 {
    return structureView(allocator, source, NodeView{ .node = node });
}

pub fn structureView(allocator: std.mem.Allocator, source: []const u8, node: anytype) std.mem.Allocator.Error![]u8 {
    return rule.run(allocator, .Layout, source, width, node);
}
