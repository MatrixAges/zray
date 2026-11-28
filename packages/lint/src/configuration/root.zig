const std = @import("std");
const zx = @import("zx");
const rule = @import("lint_config");
pub const json = @import("json.zig");

pub const yaml = struct {
    pub const Field = struct { span: zx.Span, preserve_trailing: bool };

    pub fn format(allocator: std.mem.Allocator, source: []const u8, fields: []const Field) std.mem.Allocator.Error![]u8 {
        return rule.formatYaml(allocator, source, fields);
    }
    pub fn formatEdits(allocator: std.mem.Allocator, source: []const u8, fields: []const Field) std.mem.Allocator.Error!?[]u8 {
        return rule.formatYamlEdits(allocator, source, fields);
    }
};
