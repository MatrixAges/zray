const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const modules = @import("modules.zig");
const names = @import("genz").zx.names;
pub const Initializer = frontend.project.SourceStoreInitializer;

pub const Options = struct {
    analysis: *const frontend.AnalysisResult,
    initializers: []const Initializer = &.{},
    borrowed_initializers: []const Initializer.Borrowed = &.{},
    cache: ?*@import("cache.zig") = null,
};

pub const Error = modules.Error || error{ InvalidInitializer, DuplicateInitializer, MissingInitializer };

pub fn append(bundle: *modules.Bundle, options: Options) Error!void {
    if (comptime !@import("parser_options").generated_parser) return @import("store_initializers_seed.zig").append(bundle, options);
    if (options.analysis.value != .ir or bundle.store_initializers.len != 0) return error.InvalidInitializer;

    const allocator = bundle.arena.allocator();
    const application = &options.analysis.value.ir;
    const shared_types = try names.createTypes(allocator, bundle.arena.child_allocator, application, options.analysis.nominal_types);
    var scratch = std.heap.ArenaAllocator.init(bundle.arena.child_allocator);

    defer scratch.deinit();

    var identities = try @import("store_initializers/registry.zig").create(scratch.allocator());
    const selection = try @import("store_initializers/selection.zig").plan(scratch.allocator(), application, options.analysis.store_initializers, options.initializers.len, options.borrowed_initializers.len, bundle.modules.len);
    const count: usize = @intCast(selection.count);
    var files = try std.ArrayList(modules.File).initCapacity(allocator, @intCast(selection.file_count));
    var metadata = try std.ArrayList(modules.StoreInitializer).initCapacity(allocator, count);

    files.appendSliceAssumeCapacity(bundle.modules);

    const validation = @import("store_initializers/validation.zig");
    var name_workspace = std.heap.ArenaAllocator.init(bundle.arena.child_allocator);

    defer name_workspace.deinit();

    for (0..count) |row| {
        var linked_source: Initializer = undefined;

        const initial = if (row < options.initializers.len)
            options.initializers[row].borrow()

        else if (row < selection.source_end)
            options.borrowed_initializers[row - options.initializers.len]
        else linked_row: {
            linked_source = linked(application, options.analysis.store_initializers[selection.indices[row - @as(usize, @intCast(selection.source_end))]]);

            break :linked_row linked_source.borrow();
        };

        if (!try validation.validate(bundle.arena.child_allocator, initial.program, .allowed)) return error.InvalidInitializer;

        const actual = try names.typeNamesIn(name_workspace.allocator(), initial.program, options.analysis.nominal_types);

        if (!validation.compatible(actual, shared_types)) return error.InvalidInitializer;

        _ = name_workspace.reset(.retain_capacity);

        try identities.register(initial.identity, initial.program.output_type);

        const published = try @import("publication/initializer.zig").emit(allocator, bundle.arena.child_allocator, initial.identity, initial.schema_version, initial.program, .{ .types = shared_types, .functions = &.{} }, options.cache);

        files.appendAssumeCapacity(published.file);
        metadata.appendAssumeCapacity(published.entry);
    }

    try identities.validate(&application.stores);

    bundle.modules = files.items;
    bundle.store_initializers = metadata.items;
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
