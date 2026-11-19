const std = @import("std");
const manifest = @import("../../package/manifest.zig");
const layout = @import("../../package/manifest/layout.zig");
const yaml = @import("lint").configuration.yaml;
pub const Formatted = struct { bytes: []const u8, allocated: bool = true };

pub fn format(allocator: std.mem.Allocator, source: []const u8, path: []const u8, errors: *std.Io.Writer) !?Formatted {
    var original = try manifest.parse(allocator, source);

    defer original.deinit();

    if (original.value == .diagnostic) {
        const issue = original.value.diagnostic;

        try errors.print("{s}:{d}:{d}: manifest: {s}\n", .{ path, issue.line, issue.column, issue.message });

        return null;
    }

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const fields = try layout.collect(scratch.allocator(), source);
    const formatted = try yaml.formatEdits(allocator, source, fields) orelse return .{ .bytes = source, .allocated = false };

    errdefer allocator.free(formatted);

    var updated = try manifest.parse(allocator, formatted);

    defer updated.deinit();

    if (updated.value != .data) return error.ConfigurationSemanticsChanged;

    const before = try std.json.Stringify.valueAlloc(allocator, original.value.data, .{});

    defer allocator.free(before);

    const after = try std.json.Stringify.valueAlloc(allocator, updated.value.data, .{});

    defer allocator.free(after);

    if (!std.mem.eql(u8, before, after)) return error.ConfigurationSemanticsChanged;

    return .{ .bytes = formatted };
}
