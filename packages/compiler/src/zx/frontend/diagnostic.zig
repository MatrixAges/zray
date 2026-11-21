const std = @import("std");
const zx = @import("zx");

pub fn publish(allocator: std.mem.Allocator, issue: anytype) std.mem.Allocator.Error!zx.Diagnostic {
    return .{
        .code = std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), issue.code) orelse unreachable,
        .span = .{ .start = @intCast(issue.start), .end = @intCast(issue.end) },
        .message = try allocator.dupe(u8, issue.message),
    };
}

pub fn generatedFailure(allocator: std.mem.Allocator, comptime stage: []const u8, err: anyerror) std.mem.Allocator.Error!zx.Diagnostic {
    return switch (err) {
        error.OutOfMemory, error.Overflow => error.OutOfMemory,
        else => .{
            .code = .contract,
            .span = .{ .start = 0, .end = 0 },
            .message = try std.fmt.allocPrint(allocator, "internal compiler error: generated " ++ stage ++ " failed with {s}", .{@errorName(err)}),
        },
    };
}
