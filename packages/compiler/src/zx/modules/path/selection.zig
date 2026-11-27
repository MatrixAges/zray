const std = @import("std");
const zx = @import("zx");
const Index = @import("../source_index.zig").Map;
const rule = @import("generated_project_source_selection");

pub const Selection = struct { path: []const u8, row: ?usize = null, named: bool = false };

pub fn select(allocator: std.mem.Allocator, candidate: []const u8, index: *const Index, member_width: ?usize) std.mem.Allocator.Error!Selection {
    const input: std.meta.Child(rule.Input) = .{
        .path = candidate,
        .member_width = member_width,
        .release = @ptrCast(&allocator),
        .index = &.{
            .keys = index.keys,
            .buckets = @ptrCast(&index.buckets),
            .capacity = index.buckets.len,
        },
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .path = result.owned orelse candidate,
        .row = if (result.row) |row| @intCast(row) else null,
        .named = result.named,
    };
}
