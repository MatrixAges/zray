const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const modules = @import("modules.zig");
const names = @import("genz").zx.names;
const generated = @import("parser_options").generated_parser;
pub const Initializer = frontend.project.SourceStoreInitializer;

pub const Options = struct {
    analysis: *const frontend.AnalysisResult,
    initializers: []const Initializer = &.{},
    borrowed_initializers: []const Initializer.Borrowed = &.{},
    cache: ?*@import("cache.zig") = null,
};

pub const Error = modules.Error || error{ InvalidInitializer, DuplicateInitializer, MissingInitializer };

pub fn append(bundle: *modules.Bundle, options: Options) Error!void {
    if (comptime !generated) return @import("store_initializers_seed.zig").append(bundle, options);
    if (options.analysis.value != .ir or bundle.store_initializers.len != 0) return error.InvalidInitializer;

    const application = &options.analysis.value.ir;
    const backing = bundle.arena.child_allocator;
    const owned = bundle.arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    var name_workspace = std.heap.ArenaAllocator.init(backing);

    defer name_workspace.deinit();

    const temporary = scratch.allocator();
    const existing = bundle.modules;
    const expected = try names.createTypes(owned, backing, application, options.analysis.nominal_types);
    const selection = try @import("store_initializers/selection.zig").plan(temporary, application, options.analysis.store_initializers, options.initializers.len, options.borrowed_initializers.len, existing.len);
    const count: usize = @intCast(selection.count);
    const files = try owned.alloc(modules.File, @intCast(selection.file_count));
    const entries = try owned.alloc(modules.StoreInitializer, count);

    @memcpy(files[0..existing.len], existing);

    var identities: std.StringHashMapUnmanaged(u32) = .empty;

    try identities.ensureTotalCapacity(temporary, @intCast(count));

    const validation = @import("store_initializers/validation.zig");
    const owned_count = options.initializers.len;
    const source_end: usize = @intCast(selection.source_end);

    for (0..count) |row| {
        var linked_source: Initializer = undefined;

        const initial = if (row < owned_count)
            options.initializers[row].borrow()

        else if (row < source_end)
            options.borrowed_initializers[row - owned_count]
        else blk: {
            linked_source = linked(application, options.analysis.store_initializers[@intCast(selection.indices[row - source_end])]);

            break :blk linked_source.borrow();
        };

        if (!try validation.validate(backing, initial.program, .allowed)) return error.InvalidInitializer;

        const actual = try names.typeNamesIn(name_workspace.allocator(), initial.program, options.analysis.nominal_types);

        if (actual.len != expected.len) return error.InvalidInitializer;

        for (actual, expected) |left, right| {
            if (!std.mem.eql(u8, left, right)) return error.InvalidInitializer;
        }

        const found = identities.getOrPutAssumeCapacity(initial.identity);

        if (found.found_existing) return error.DuplicateInitializer;

        found.value_ptr.* = @backingInt(initial.program.output_type);
        _ = name_workspace.reset(.retain_capacity);
        const published = try @import("publication/initializer.zig").emit(owned, backing, initial.identity, initial.schema_version, initial.program, .{ .types = expected, .functions = &.{} }, options.cache);
        files[existing.len + row] = published.file;
        entries[row] = published.entry;
    }

    for (application.stores.paths, application.stores.types) |path, expected_type| {
        const actual_type = identities.get(path) orelse return error.MissingInitializer;

        if (actual_type != expected_type) return error.InvalidInitializer;
    }

    bundle.modules = files;
    bundle.store_initializers = entries;
}

fn linked(application: *const zx.ir.Program, initial: frontend.project.compiled.StoreInitializer) Initializer {
    const function = application.functions.at(@backingInt(initial.function));

    return .{
        .identity = initial.identity,
        .schema_version = initial.schema_version,
        .program = .{
            .file_name = function.file_name,
            .types = application.types,
            .input_type = function.input_type,
            .output_type = function.output_type,
            .output_ownership = function.output_ownership,
            .symbols = function.symbols,
            .expressions = function.expressions,
            .body = function.body,
            .contracts = function.contracts,
            .stores = function.stores,
            .store_mode = function.store_mode,
        },
    };
}
