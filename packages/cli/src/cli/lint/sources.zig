const std = @import("std");
const Module = @import("../library/analyze.zig").Module;
const Item = @import("cli_abi").layouts.@"zig:lint_workflow_host".LintItem;

pub fn collectItems(allocator: std.mem.Allocator, modules: []const Module, root: []const u8) ![]const *const Item {
    var count: usize = 0;

    for (modules) |module| count += module.sources.len + module.store_definitions.len;

    const values = try allocator.alloc(Item, count);
    const rows = try allocator.alloc(*const Item, count);
    var index: usize = 0;

    for (modules) |module| {
        for (module.sources) |source| {
            values[index] = .{ .path = source.path, .source = source.source };
            index += 1;
        }

        for (module.store_definitions) |definition| {
            const path = try std.fs.path.resolve(allocator, &.{ root, definition.source_path });

            values[index] = .{ .path = path, .source = null };
            index += 1;
        }
    }

    for (values, rows) |*value, *row| row.* = value;

    return rows;
}
