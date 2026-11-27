const std = @import("std");
const zx = @import("zx");
const rule = @import("generated_zig_path_index");
pub const Index = std.meta.Child(rule.Output);

pub fn build(allocator: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!Index {
    const output = rule.executeIn(allocator, paths) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => @panic("invalid path index input"),
    };

    return zx.columns.view(Index, output);
}
