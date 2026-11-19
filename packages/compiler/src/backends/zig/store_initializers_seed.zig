const std = @import("std");
const ir = @import("zx").ir;
const frontend = @import("frontend");
const modules = @import("modules.zig");
const names = @import("names.zig");
pub const Initializer = @import("frontend").project.SourceStoreInitializer;
const Options = @import("store_initializers.zig").Options;

pub const Error = modules.Error || error{ InvalidInitializer, DuplicateInitializer, MissingInitializer };

pub fn append(bundle: *modules.Bundle, options: Options) Error!void {
    if (options.analysis.value != .ir or bundle.store_initializers.len != 0) return error.InvalidInitializer;

    const allocator = bundle.arena.allocator();
    const application = options.analysis.value.ir;
    const shared = try names.create(allocator, bundle.arena.child_allocator, application, options.analysis.nominal_types);
    var files: std.ArrayList(modules.File) = .empty;
    var metadata: std.ArrayList(modules.StoreInitializer) = .empty;
    var identities: std.StringHashMapUnmanaged(ir.TypeId) = .empty;

    try files.appendSlice(allocator, bundle.modules);

    var initializers: std.ArrayList(Initializer) = .empty;

    try initializers.appendSlice(allocator, options.initializers);

    for (options.borrowed_initializers) |initial| {
        try initializers.append(allocator, .{
            .identity = initial.identity,
            .schema_version = initial.schema_version,
            .program = initial.program.*,
        });
    }

    for (options.analysis.store_initializers) |initial| {
        const needed = for (0..application.stores.count()) |store_index| {
            const slot = application.stores.at(store_index);

            if (std.mem.eql(u8, slot.path, initial.identity)) break true;
        } else false;

        if (!needed) continue;
        if (@backingInt(initial.function) >= application.functions.count()) return error.InvalidInitializer;

        const function = application.functions.at(@backingInt(initial.function));

        if (function.external != null) return error.InvalidInitializer;

        try initializers.append(allocator, .{
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
        });
    }

    for (initializers.items) |initial| {
        const program = initial.program;

        if (program.type_only or program.functions.count() != 0 or program.stores.count() != 0 or program.contracts.count() != 0) return error.InvalidInitializer;
        if (try frontend.validateIr(allocator, program) != null) return error.InvalidInitializer;
        if (program.types.at(@backingInt(program.input_type)) != .scalar or program.types.at(@backingInt(program.input_type)).scalar != .void) return error.InvalidInitializer;
        if (program.types.at(@backingInt(program.output_type)) != .object) return error.InvalidInitializer;

        const own = try names.create(allocator, bundle.arena.child_allocator, program, options.analysis.nominal_types);

        if (own.types.len != shared.types.len) return error.InvalidInitializer;
        for (own.types, shared.types) |left, right| if (!std.mem.eql(u8, left, right)) return error.InvalidInitializer;

        const found = try identities.getOrPut(allocator, initial.identity);

        if (found.found_existing) return error.DuplicateInitializer;

        found.value_ptr.* = program.output_type;
        const published = try @import("publication/initializer.zig").emit(allocator, bundle.arena.child_allocator, initial.identity, initial.schema_version, &program, .{ .types = shared.types, .functions = &.{} }, options.cache);

        try files.append(allocator, published.file);
        try metadata.append(allocator, published.entry);
    }

    for (0..application.stores.count()) |store_index| {
        const slot = application.stores.at(store_index);
        const type_id = identities.get(slot.path) orelse return error.MissingInitializer;

        if (type_id != slot.type_id) return error.InvalidInitializer;
    }

    const expanded = try files.toOwnedSlice(allocator);
    const stores = try metadata.toOwnedSlice(allocator);

    bundle.modules = expanded;
    bundle.store_initializers = stores;
}
