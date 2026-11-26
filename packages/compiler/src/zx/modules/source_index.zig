const std = @import("std");
const columns = @import("zx").columns;
pub const Map = if (@import("parser_options").generated_parser) @import("source_index/fixed.zig") else @import("source_index/seed.zig");
pub const Owned = @import("source_index/owned.zig");

pub fn emptyGenerated(comptime State: type) State {
    const indirect = @typeInfo(State) == .pointer;
    const Index = if (indirect) std.meta.Child(State) else State;

    const Empty = struct {
        const Origin = if (@hasField(Index, "zx_origin"))
            std.meta.Child(@typeInfo(@FieldType(Index, "zx_origin")).optional.child)
        else
            struct {
                keys: []const []const u8,
                values: []const u32,
                buckets: []const ?u32,
            };

        const source: Origin = .{
            .keys = &.{},
            .values = &.{},
            .buckets = &.{},
        };

        const index: Index = columns.borrow(Index, &source);
    };

    return if (indirect) &Empty.index else Empty.index;
}

/// The map and canonical keys belong to the surrounding analysis arena.
pub fn buildIn(allocator: std.mem.Allocator, sources: anytype, root: []const u8) std.mem.Allocator.Error!*const Map {
    const result = try allocator.create(Map);

    result.* = try Map.init(allocator, sources.len);

    for (sources, 0..) |source, index| {
        const path = try std.fs.path.resolve(allocator, &.{ root, source.path });

        if (!result.claim(index, path)) allocator.free(path);
    }

    return result;
}

pub const Known = struct {
    paths: *const Map,
    matched_row: ?*?usize = null,
    pub fn has(self: Known, path: []const u8) std.mem.Allocator.Error!bool {
        const row = self.paths.get(path);

        if (self.matched_row) |matched| matched.* = row;

        return row != null;
    }
};
