const std = @import("std");
const zx = @import("zx");
const spacing = @import("../spacing.zig");
const rule = @import("lint_config");

pub const Field = struct { span: zx.Span, preserve_trailing: bool };

pub fn format(allocator: std.mem.Allocator, source: []const u8, fields: []const Field) std.mem.Allocator.Error![]u8 {
    return try formatEdits(allocator, source, fields) orelse allocator.dupe(u8, source);
}

pub fn formatEdits(allocator: std.mem.Allocator, source: []const u8, fields: []const Field) std.mem.Allocator.Error!?[]u8 {
    if (fields.len < 2) return null;

    const planned = try rule.yamlEdits(allocator, source, fields);

    defer allocator.free(planned);

    if (planned.len == 0) return null;

    const edits = try allocator.alloc(spacing.Edit, planned.len);

    defer allocator.free(edits);

    for (planned, edits) |item, *edit| edit.* = .{
        .span = .{ .start = item.start, .end = item.end },
        .replacement = item.replacement,
    };

    return try spacing.format(allocator, source, edits);
}
