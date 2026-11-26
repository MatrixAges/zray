const std = @import("std");
const zx = @import("zx");
const rule = @import("lint_config");

pub const Field = struct { span: zx.Span, preserve_trailing: bool };

pub fn format(allocator: std.mem.Allocator, source: []const u8, fields: []const Field) std.mem.Allocator.Error![]u8 {
    return try formatEdits(allocator, source, fields) orelse allocator.dupe(u8, source);
}

pub fn formatEdits(allocator: std.mem.Allocator, source: []const u8, fields: []const Field) std.mem.Allocator.Error!?[]u8 {
    if (fields.len < 2) return null;

    return rule.formatYaml(allocator, source, fields);
}
