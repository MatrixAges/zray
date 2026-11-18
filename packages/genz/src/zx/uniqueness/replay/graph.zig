const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;

pub const Storage = if (generated) struct {
    starts: []const u64,
    edges: []const u32,
} else []const []const u32;

/// Owns the call graph in the trace's arena after compilation scratch is released.
pub fn capture(allocator: std.mem.Allocator, callees: []const []const u32) std.mem.Allocator.Error!Storage {
    if (!generated) {
        const rows = try allocator.alloc([]const u32, callees.len);

        for (rows, callees) |*target, source| target.* = try allocator.dupe(u32, source);

        return rows;
    }

    const entry = @import("generated_uniqueness_trace_graph");
    const Input = std.meta.Child(entry.Input);
    const starts = try allocator.alloc(u64, callees.len + 1);
    var edges: []u32 = &.{};
    const input: Input = .{ .callees = callees, .starts = @ptrCast(&starts), .edges = @ptrCast(&edges) };

    zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("trace graph publication failed: {s}", .{@errorName(err)}),
    };

    return .{ .starts = starts, .edges = edges };
}
