const std = @import("std");
const model = @import("../../compiled.zig");
const load_model = @import("../load.zig");
const Destination = load_model.Destination;
const generated = @import("generated_compiled_library");
const Input = @import("input.zig");

const Options = struct {
    seed: bool = false,
    selected: ?[]const model.PublicReference = null,
    call_scratch: ?load_model.CallScratch = null,
    export_buckets: ?[]u64 = null,
};

pub fn loadOptions(allocator: std.mem.Allocator, options: load_model.Options) !model.Loaded {
    var types = try @import("../../../analysis/type_table.zig").storage(allocator, options.types);
    var origins = try @import("../../nominal_origins.zig").copy(allocator, options.nominal_types);

    return loadPrepared(allocator, options.library, .{
        .types = &types,
        .origins = &origins,
        .functions = options.functions,
        .native_modules = options.native_modules,
    }, .{
        .seed = true,
        .selected = options.selected,
    });
}

pub fn loadCalls(allocator: std.mem.Allocator, library: model.Library, destination: Destination, scratch: load_model.CallScratch, seed: bool) !void {
    _ = try loadPrepared(allocator, library, destination, .{
        .seed = seed,
        .call_scratch = scratch,
        .export_buckets = scratch.export_buckets,
    });
}

pub fn load(allocator: std.mem.Allocator, library: model.Library, destination: Destination, export_buckets: ?[]u64) !model.Loaded {
    return loadPrepared(allocator, library, destination, .{ .export_buckets = export_buckets });
}

fn loadPrepared(allocator: std.mem.Allocator, library: model.Library, destination: Destination, options: Options) !model.Loaded {
    var arena = std.heap.ArenaAllocator.init(if (options.call_scratch) |scratch| scratch.temporary else allocator);

    defer arena.deinit();

    const graph = model.Graph{ .program = library.program, .exports = library.exports, .nominal_types = library.nominal_types, .store_initializers = library.store_initializers };
    var input: Input = undefined;

    try input.init(arena.allocator(), &graph, library.instance, library.artifact, destination, options.seed, options.selected);

    var index: std.meta.Child(@typeInfo(@FieldType(@TypeOf(input.input), "export_index")).optional.child) = undefined;

    const export_buckets = options.export_buckets orelse if (options.selected != null and options.selected.?.len > 1 and library.exports.len > 1)
        (try model.ExportIndex.init(arena.allocator(), library.exports.len)).buckets()

    else
        null;

    if (export_buckets) |*buckets| {
        index = .{ .buckets = @ptrCast(buckets), .capacity = buckets.len };
        input.input.export_index = &index;
    }

    const result = generated.execute(&arena, &input.input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (result.status) {
        0 => {},
        1 => return error.InvalidLibrary,
        2 => return error.InvalidModule,
        3 => return error.MissingNominalOrigin,
        4 => return error.ConflictingNominalType,
        5 => return error.ConflictingInterface,
        6 => return error.OutOfMemory,
        7 => return error.InvalidNominalTypes,
        8 => return error.MissingPublicModule,
        else => unreachable,
    }

    return @import("publish.zig").apply(allocator, arena.allocator(), &input, &library, result, destination, options.call_scratch);
}
