const std = @import("std");
const zx = @import("zx");
const generated = @import("generated_project_source_alias");
const Map = @import("../../source_index.zig").Map;
const SourceSelection = @import("host.zig").SourceSelection;

pub fn select(allocator: std.mem.Allocator, candidate: []const u8, index: *const Map) std.mem.Allocator.Error!SourceSelection {
    const input: std.meta.Child(generated.Input) = .{
        .path = candidate,
        .index = &.{
            .keys = index.keys,
            .buckets = @ptrCast(&index.buckets),
            .capacity = index.buckets.len,
        },
    };

    const result = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        else => unreachable,
    };

    defer if (comptime @typeInfo(@TypeOf(result)) == .pointer) allocator.destroy(result);

    if (result.row) |row| return .{ .path = result.fallback orelse candidate, .row = @intCast(row) };
    if (result.fallback) |fallback| allocator.free(fallback);

    return .{ .path = candidate };
}
