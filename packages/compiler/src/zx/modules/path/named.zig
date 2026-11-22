const std = @import("std");
const zx = @import("zx");
const Known = @import("../source_index.zig").Known;
const CallSource = @import("../module_path.zig").CallSource;
const rule = @import("generated_project_named_source");

pub fn select(allocator: std.mem.Allocator, candidate: []const u8, member: []const u8, known: Known) std.mem.Allocator.Error!CallSource {
    var output = [_][]const u8{""};

    errdefer allocator.free(output[0]);

    const input: std.meta.Child(rule.Input) = .{
        .path = candidate,
        .member_width = member.len,
        .release = @ptrCast(&allocator),
        .output = &output,
        .index = &.{
            .keys = known.paths.keys,
            .buckets = @ptrCast(&known.paths.buckets),
            .capacity = known.paths.buckets.len,
        },
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        else => unreachable,
    };

    if (known.matched_row) |row| {
        row.* = if (result.row) |value| @intCast(value) else null;
    }

    return .{
        .path = if (output[0].len == 0) candidate else output[0],
        .named = result.named,
    };
}
