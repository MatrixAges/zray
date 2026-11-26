const std = @import("std");
const model = @import("../../library/root.zig");
const modules = @import("modules.zig");
const Names = @import("genz").zx.modules.Names;
const Cache = @import("cache.zig");
const generated = @import("parser_options").generated_parser;

pub const Result = struct { files: []const modules.File, entries: []const modules.StoreInitializer };

pub fn create(allocator: std.mem.Allocator, library: *const model.Result, names: Names, cache: ?*Cache) modules.Error!Result {
    return createBacked(allocator, allocator, library, names, cache);
}

pub fn createBacked(allocator: std.mem.Allocator, backing: std.mem.Allocator, library: *const model.Result, names: Names, cache: ?*Cache) modules.Error!Result {
    const count = library.store_initializers.len;
    const files = try allocator.alloc(modules.File, count);
    const entries = try allocator.alloc(modules.StoreInitializer, count);

    var frame: Publication = .{
        .output = allocator,
        .backing = backing,
        .library = library,
        .names = names,
        .cache = cache,
        .files = files,
        .entries = entries,
    };

    if (comptime generated) {
        const entry = @import("generated_library_initializer_workflow");
        var fixed = std.heap.FixedBufferAllocator.init(&.{});
        const input: std.meta.Child(entry.Input) = .{ .target = @ptrCast(&frame), .count = count };
        const published: usize = @intCast(try entry.executeValue(fixed.allocator(), &input));

        return .{ .files = files[0..published], .entries = entries[0..published] };
    } else {
        for (0..count) |row| try frame.emit(row);
    }

    return .{ .files = files, .entries = entries };
}

const Publication = struct {
    output: std.mem.Allocator,
    backing: std.mem.Allocator,
    library: *const model.Result,
    names: Names,
    cache: ?*Cache,
    files: []modules.File,
    entries: []modules.StoreInitializer,
    fn emit(self: *const @This(), row: usize) modules.Error!void {
        const initial = self.library.store_initializers[row];
        var program = self.library.program;

        @import("../../library/entry_view.zig").apply(&program, initial.function, true);

        program.exports = &.{};

        const published = try @import("publication/initializer.zig").emit(self.output, self.backing, initial.identity, initial.schema_version, &program, self.names, self.cache);

        self.files[row] = published.file;
        self.entries[row] = published.entry;
    }
};

pub fn emitLibraryInitializer(handle: *const anyopaque, row: u64) modules.Error!void {
    const frame: *const Publication = @ptrCast(@alignCast(handle));

    return frame.emit(@intCast(row));
}
