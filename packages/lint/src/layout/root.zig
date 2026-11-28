const std = @import("std");
const rule = @import("lint_layout");
pub const Projection = @import("projection.zig").Projection;
pub const use_default_width = 0;

pub fn format(allocator: std.mem.Allocator, source: []const u8, projection: *const Projection, width: usize, level: usize) std.mem.Allocator.Error![]u8 {
    return apply(allocator, source, projection, .{ .width = width, .level = level }, null);
}

pub fn formatWithLineEnding(allocator: std.mem.Allocator, source: []const u8, projection: *const Projection, width: usize, level: usize, newline: []const u8) std.mem.Allocator.Error![]u8 {
    return apply(allocator, source, projection, .{ .width = width, .level = level }, newline);
}

pub fn indent(allocator: std.mem.Allocator, source: []const u8, projection: *const Projection, level: usize) std.mem.Allocator.Error![]u8 {
    return apply(allocator, source, projection, .{ .level = level, .indent_only = true }, "\n");
}

pub fn formatAttribute(allocator: std.mem.Allocator, source: []const u8, projection: *const Projection, level: usize, prefix: usize, newline: []const u8) std.mem.Allocator.Error![]u8 {
    return apply(allocator, source, projection, .{ .level = level, .prefix = prefix, .suffix = 1 }, newline);
}

fn apply(allocator: std.mem.Allocator, source: []const u8, projection: *const Projection, options: rule.Options, newline: ?[]const u8) std.mem.Allocator.Error![]u8 {
    if (projection.failed) return error.OutOfMemory;

    return rule.format(allocator, source, .{ .raw_tokens = projection.raw_tokens, .raw_comments = projection.raw_comments, .ops = projection.ops.items }, options, newline);
}
