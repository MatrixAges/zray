const std = @import("std");
const model = @import("../../compiled.zig");
const load_model = @import("../load.zig");
const Destination = load_model.Destination;
const generated = @import("generated_compiled_library");
const generated_publish = @import("generated_compiled_library_publish");
const Input = @import("input.zig");
const Installation = @import("installation.zig");
const StoreState = std.meta.Child(@FieldType(generated.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

const Options = struct {
    seed: bool = false,
    selected: ?[]const model.PublicReference = null,
    call_scratch: ?load_model.CallScratch = null,
    export_buckets: ?[]u64 = null,
    initializer_tail: ?[]model.StoreInitializer = null,
};

pub fn loadOptions(allocator: std.mem.Allocator, options: load_model.Options) !model.Loaded {
    var types = try @import("../../../analysis/type_table.zig").storage(allocator, options.types);
    var origins = try @import("../../nominal_origins.zig").copy(allocator, options.nominal_types);

    return load(allocator, options.library, .{
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
    _ = try load(allocator, library, destination, .{
        .seed = seed,
        .call_scratch = scratch,
        .export_buckets = scratch.export_buckets,
    });
}

pub fn load(allocator: std.mem.Allocator, library: model.Library, destination: Destination, options: Options) !model.Loaded {
    var arena = std.heap.ArenaAllocator.init(if (options.call_scratch) |scratch| scratch.temporary else allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const graph = model.Graph{ .program = library.program, .exports = library.exports, .nominal_types = library.nominal_types, .store_initializers = library.store_initializers };
    var input: Input = undefined;
    var installation: Installation = undefined;
    var state_value: std.meta.Child(StoreState) = .{ .preparing = false };
    var state_ptr: StoreState = &state_value;
    var host: StoreHost = .{ .store_0 = &state_ptr };

    input.init(temporary, &graph, library.instance, library.artifact, destination, options.seed, options.selected, options.export_buckets);
    installation.init(&allocator, &input, &library, destination, options.call_scratch, options.initializer_tail);
    defer @import("../../column_lengths.zig").publish(&installation.functions.lengths, installation.functions.completed[0]);
    errdefer installation.types.release();

    const request: std.meta.Child(generated.Input) = .{
        .plan = &input.input,
        .installation = &installation.input,
        .temporary = @ptrCast(&temporary),
    };

    const plan = generated.executeIn(temporary, &request, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return if (state_ptr.preparing) error.OutOfMemory else error.InvalidModule,
    };

    switch (plan.status) {
        .Ready => {},
        .InvalidLibrary => return error.InvalidLibrary,
        .InvalidModule => return error.InvalidModule,
        .MissingNominalOrigin => return error.MissingNominalOrigin,
        .ConflictingNominalType => return error.ConflictingNominalType,
        .ConflictingInterface => return error.ConflictingInterface,
        .OutOfMemory => return error.OutOfMemory,
        .InvalidNominalTypes => return error.InvalidNominalTypes,
        .MissingPublicModule => return error.MissingPublicModule,
    }

    const publication: std.meta.Child(generated_publish.Input) = .{
        .installation = &installation.input,
        .plan = if (@typeInfo(@TypeOf(plan)) == .pointer) plan else &plan,
    };

    generated_publish.executeIn(installation.owner, &publication) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return installation.result(destination, library.program.functions.count());
}
