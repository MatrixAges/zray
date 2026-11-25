const std = @import("std");
const rule = @import("lint_layout");
const spacing = @import("../spacing.zig");
pub const Token = rule.Token;
pub const Projection = @import("projection.zig").Projection;
pub const use_default_width = 0;

pub fn format(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, width: usize, level: usize) std.mem.Allocator.Error![]u8 {
    const newline: []const u8 = if (std.mem.indexOf(u8, source, "\r\n") != null) "\r\n" else "\n";

    return formatWithLineEnding(allocator, source, tokens, width, level, newline);
}

pub fn formatWithLineEnding(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, width: usize, level: usize, newline: []const u8) std.mem.Allocator.Error![]u8 {
    return apply(allocator, source, tokens, .{ .width = width, .level = level }, newline);
}

pub fn indent(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, level: usize) std.mem.Allocator.Error![]u8 {
    return apply(allocator, source, tokens, .{ .level = level, .indent_only = true }, "\n");
}

pub fn formatAttribute(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, level: usize, prefix: usize, newline: []const u8) std.mem.Allocator.Error![]u8 {
    return apply(allocator, source, tokens, .{ .level = level, .prefix = prefix, .suffix = 1 }, newline);
}

fn apply(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, options: rule.Options, newline: []const u8) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const planned = try rule.edits(temporary, source, tokens, options);
    const edits = try temporary.alloc(spacing.Edit, planned.len);

    for (planned, edits) |item, *edit| {
        const prefix_len = if (item.newline) newline.len else 0;
        const replacement = try temporary.alloc(u8, prefix_len + item.count);

        if (item.newline) @memcpy(replacement[0..prefix_len], newline);

        @memset(replacement[prefix_len..], ' ');

        edit.* = .{ .span = .{ .start = item.start, .end = item.end }, .replacement = replacement };
    }

    return spacing.format(allocator, source, edits);
}
