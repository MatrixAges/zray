const std = @import("std");
const model = @import("../../library/root.zig");
const modules = @import("modules.zig");
const Names = @import("genz").zx.modules.Names;
const Cache = @import("cache.zig");

pub const Result = struct { files: []const modules.File, entries: []const modules.StoreInitializer };

pub fn create(allocator: std.mem.Allocator, library: *const model.Result, names: Names, cache: ?*Cache) modules.Error!Result {
    return createBacked(allocator, allocator, library, names, cache);
}

pub fn createBacked(allocator: std.mem.Allocator, backing: std.mem.Allocator, library: *const model.Result, names: Names, cache: ?*Cache) modules.Error!Result {
    const files = try allocator.alloc(modules.File, library.store_initializers.len);
    const entries = try allocator.alloc(modules.StoreInitializer, library.store_initializers.len);

    for (library.store_initializers, files, entries) |initial, *file, *entry| {
        var program = library.program;
        @import("../../library/entry_view.zig").apply(&program, initial.function, true);
        program.exports = &.{};
        const published = try @import("publication/initializer.zig").emit(allocator, backing, initial.identity, initial.schema_version, &program, names, cache);
        file.* = published.file;
        entry.* = published.entry;
    }

    return .{ .files = files, .entries = entries };
}
