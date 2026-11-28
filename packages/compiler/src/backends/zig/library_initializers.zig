const std = @import("std");
const zx = @import("zx");
const model = @import("../../library/root.zig");
const modules = @import("modules.zig");
const Names = @import("genz").zx.modules.Names;
const Cache = @import("cache.zig");
const Identity = @import("publication/identity.zig");
const Initializer = @import("publication/initializer.zig");
const generated = @import("parser_options").generated_parser;

pub const Result = struct { files: []const modules.File, entries: []const modules.StoreInitializer };

pub fn create(allocator: std.mem.Allocator, library: *const model.Result, names: Names, cache: ?*Cache) modules.Error!Result {
    return createBacked(allocator, allocator, library, names, cache);
}

pub fn createBacked(allocator: std.mem.Allocator, backing: std.mem.Allocator, library: *const model.Result, names: Names, cache: ?*Cache) modules.Error!Result {
    const count = library.store_initializers.len;
    const files = try allocator.alloc(modules.File, count);
    const entries = try allocator.alloc(modules.StoreInitializer, count);

    if (comptime generated) {
        const rule = @import("generated_library_initializer_workflow");
        const Input = std.meta.Child(std.meta.Elem(rule.Input));
        var arena = std.heap.ArenaAllocator.init(backing);

        defer arena.deinit();

        const scratch = arena.allocator();
        const rows = try scratch.alloc(Input, count);
        const pointers = try scratch.alloc(*const Input, count);

        for (library.store_initializers, rows, pointers) |initializer, *row, *pointer| {
            row.* = .{ .identity = initializer.identity, .function = @backingInt(initializer.function), .schema_version = initializer.schema_version };
            pointer.* = row;
        }

        const prepared = rule.executeIn(scratch, pointers) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        for (prepared, files, entries) |row, *file, *entry| {
            const identity = try Identity.pack(allocator, row.identity, row.prefix, row.digest);
            const program = initializerProgram(library, @fromBackingInt(row.function));
            const published = try Initializer.emitPrepared(allocator, backing, identity, row.schema_version, &program, names, cache);
            file.* = published.file;
            entry.* = published.entry;
        }
    } else {
        for (library.store_initializers, files, entries) |row, *file, *entry| {
            const program = initializerProgram(library, row.function);
            const published = try Initializer.emit(allocator, backing, row.identity, row.schema_version, &program, names, cache);

            file.* = published.file;
            entry.* = published.entry;
        }
    }

    return .{ .files = files, .entries = entries };
}

fn initializerProgram(library: *const model.Result, function: zx.ir.FunctionId) zx.ir.Program {
    var program = library.program;

    @import("../../library/entry_view.zig").apply(&program, function, true);

    program.exports = &.{};

    return program;
}
