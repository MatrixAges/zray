const std = @import("std");
const Source = @import("../modules.zig").Source;
const module_reference = @import("../module_reference.zig");
const paths = @import("../paths.zig");
const dependency = @import("reference.zig");

pub fn reachable(allocator: std.mem.Allocator, sources: []const Source, entry: []const u8) ![]const Source {
    var registered: std.StringHashMapUnmanaged(usize) = .empty;

    defer registered.deinit(allocator);

    for (sources, 0..) |source, index| try registered.put(allocator, source.path, index);

    const seen = try allocator.alloc(bool, sources.len);

    defer allocator.free(seen);

    @memset(seen, false);

    var pending: std.ArrayList(usize) = .empty;
    var references: dependency.Iterator = .{};

    defer pending.deinit(allocator);
    defer references.deinit(allocator);

    try pending.append(allocator, registered.get(entry) orelse return error.MissingParserEntry);

    while (pending.pop()) |index| {
        if (seen[index]) continue;

        seen[index] = true;

        const source = &sources[index];

        references.reset(&source.node, source.references);

        while (try references.next(allocator, true)) |selection| {
            const attribute = selection.attribute orelse continue;

            if (selection.package_allowed and module_reference.isPackage(attribute.value, source.packages)) continue;

            const path = try paths.resolve(allocator, source.path, attribute.value);

            defer allocator.free(path);

            try pending.append(allocator, registered.get(path) orelse return error.MissingParserModule);
        }
    }

    var result: std.ArrayList(Source) = .empty;

    for (sources, seen) |source, selected| if (selected) try result.append(allocator, source);

    return result.toOwnedSlice(allocator);
}
