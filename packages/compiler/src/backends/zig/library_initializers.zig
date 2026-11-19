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
        const function = library.program.functions.at(@backingInt(initial.function));
        var program = library.program;
        program.type_only = false;
        program.input_type = function.input_type;
        program.output_type = function.output_type;
        program.output_ownership = function.output_ownership;
        program.symbols = function.symbols;
        program.expressions = function.expressions;
        program.body = function.body;
        program.contracts = function.contracts;
        program.stores = .{};
        program.exports = &.{};
        const published = try @import("publication/initializer.zig").emit(allocator, backing, initial.identity, initial.schema_version, &program, names, cache);
        file.* = published.file;
        entry.* = published.entry;
    }

    return .{ .files = files, .entries = entries };
}
