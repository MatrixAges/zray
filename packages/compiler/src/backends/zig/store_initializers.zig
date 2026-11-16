const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const modules = @import("modules.zig");
const names = @import("names.zig");
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
    const shared = try names.create(allocator, bundle.arena.child_allocator, application.*, options.analysis.nominal_types);
    var scratch = std.heap.ArenaAllocator.init(bundle.arena.child_allocator);

    defer scratch.deinit();

    var identities = try @import("store_initializers/registry.zig").create(scratch.allocator());
    const entry = @import("generated_store_initializer_selection");
    const Input = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;

    const input: Input = .{
        .initializers = zx.columns.storage.view(@FieldType(Input, "initializers"), options.analysis.store_initializers),
        .paths = application.stores.paths,
        .function_count = application.functions.count(),
        .native_modules = application.functions.native_modules,
        .zx_origin = null,
    };

    const selection = entry.executeValue(scratch.allocator(), input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!selection.valid) return error.InvalidInitializer;

    const source_count = std.math.add(usize, options.initializers.len, options.borrowed_initializers.len) catch return error.OutOfMemory;
    const count = std.math.add(usize, source_count, selection.indices.len) catch return error.OutOfMemory;
    const file_count = std.math.add(usize, bundle.modules.len, count) catch return error.OutOfMemory;
    var files = try std.ArrayList(modules.File).initCapacity(allocator, file_count);
    var metadata = try std.ArrayList(modules.StoreInitializer).initCapacity(allocator, count);

    files.appendSliceAssumeCapacity(bundle.modules);

    const validation = @import("store_initializers/validation.zig");

    for (0..count) |row| {
        var linked_source: Initializer = undefined;

        const initial = if (row < options.initializers.len)
            options.initializers[row].borrow()

        else if (row < source_count)
            options.borrowed_initializers[row - options.initializers.len]
        else linked_row: {
            linked_source = linked(application, options.analysis.store_initializers[selection.indices[row - source_count]]);

            break :linked_row linked_source.borrow();
        };

        if (!try validation.validate(bundle.arena.child_allocator, initial.program, .allowed)) return error.InvalidInitializer;

        const own = try names.create(allocator, bundle.arena.child_allocator, initial.program.*, options.analysis.nominal_types);

        if (!validation.compatible(own.types, shared.types)) return error.InvalidInitializer;

        const identity = try allocator.dupe(u8, initial.identity);

        try identities.register(identity, initial.program.output_type);

        var digest: [32]u8 = undefined;

        zx.Sha256.hash(identity, &digest, .{});

        const module_name = try std.fmt.allocPrint(allocator, "zxc_store_initial_{s}", .{std.fmt.bytesToHex(digest, .lower)});
        var program = initial.program.*;
        program.file_name = module_name;
        const source = try modules.emit(allocator, program, .{ .types = shared.types, .functions = &.{} }, .entry, options.cache);

        files.appendAssumeCapacity(.{ .name = module_name, .source = source, .imports = &.{} });
        metadata.appendAssumeCapacity(.{ .identity = identity, .schema_version = initial.schema_version, .module_name = module_name, .type_name = shared.types[@backingInt(program.output_type)] });
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
