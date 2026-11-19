const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Types = @import("../types.zig");
const Origins = @import("../../nominal_origins.zig");
const Registry = @import("../../compiled/initializer_registry.zig");
const Initializer = @import("../../source_store_initializer.zig");
const Nodes = @import("../../artifact/nodes.zig");
const publication = @import("../../artifact/materializing/publication/host.zig");
const comparison = @import("../../../ir/compare/initializer.zig");
const merge = @import("../../../analysis/semantic/merge.zig");
const TypePublication = @import("../../../analysis/semantic/merging/publication/view.zig");
const plan = @import("generated_source_initializer_prepare");
const Input = std.meta.Child(plan.Input);
const Program = std.meta.Child(@FieldType(Input, "program"));
const Validation = @import("../../../ir/canonical/validation/input.zig").Storage(Program);
const TypeRegistration = std.meta.Child(@FieldType(Input, "types"));
const Lookup = std.meta.Child(@FieldType(Input, "registry"));
const Registration = publication.InitializerRegistration;
const Error = Types.Error || @import("../../artifact/model.zig").Error || error{ InvalidInitializer, ConflictingInitializer };

pub fn publish(types: *Types, scratch: std.mem.Allocator, functions: *ir.FunctionStorage, registry: *Registry, initial: Initializer.Borrowed, origins: Origins.Table) Error!void {
    var arena = std.heap.ArenaAllocator.init(scratch);

    defer arena.deinit();

    const temporary = arena.allocator();
    var mapping: []u32 = &.{};
    const selected = try prepare(types, temporary, functions.count(), registry, initial, origins, &mapping);

    switch (selected.status) {
        .Append => {},
        .Compare => {
            const table = functions.view();

            if (!comparison.source(&table, selected.function, initial, mapping)) return error.ConflictingInitializer;

            return;
        },
        .Conflict => return error.ConflictingInitializer,
        .InvalidInitializer => return error.InvalidInitializer,
        .MissingOrigin => return error.MissingNominalOrigin,
        .ConflictingType => return error.ConflictingNominalType,
        .Exhausted => return error.OutOfMemory,
        .Invalid => return error.InvalidModule,
    }

    const nodes: Nodes = .{
        .allocator = types.allocator,
        .types = .{ .mapped = @ptrCast(mapping) },
        .functions = .{ .indexed = &.{} },
        .native_modules = .{ .indexed = &.{} },
    };

    var writer: Registry.Writer(std.meta.Child(@FieldType(Registration, "registry"))) = undefined;

    writer.init(registry, true);
    defer writer.finish(registry);

    return publication.appendInitializer(&nodes, functions, initial.program, temporary, &.{
        .registry = &writer.input,
        .identity = initial.identity,
        .version = initial.schema_version,
        .slot = selected.slot,
        .function = selected.function,
    });
}

fn prepare(types: *Types, temporary: std.mem.Allocator, functions: usize, registry: *const Registry, initial: Initializer.Borrowed, origins: Origins.Table, mapping: *[]u32) Error!std.meta.Child(plan.Output) {
    const program = initial.program;
    var validation: Validation = undefined;

    validation.init(temporary, program, .{});

    const request: merge.Request = .{
        .allocator = types.allocator,
        .mapping_allocator = temporary,
        .temporary = temporary,
        .source = program.types,
        .origins = origins,
        .items = &types.items,
        .nominal = &types.origins.items,
        .first = 0,
        .checked = true,
        .complete = true,
    };

    var type_mapping: merge.View = undefined;

    type_mapping.init(&request, mapping);

    const offsets = TypePublication.offsets(request.items);

    const options: TypePublication.Options = .{
        .allocator = request.allocator,
        .payload = request.allocator,
        .types = request.items,
        .origins = request.nominal,
        .offsets = &offsets,
    };

    var type_output: TypePublication = undefined;

    type_output.init(&options, .{}, @as(Origins.Table, .{}));
    errdefer type_output.release(&options);

    const rows = Registry.readRows(registry.rows.items);
    const keys = rows.view(std.meta.Child(@FieldType(Lookup, "source")));
    var started: [1]u8 = .{0};
    const marker: []u8 = &started;

    const input: Input = .{
        .eligibility = &.{
            .type_only = program.type_only,
            .function_count = program.functions.count(),
            .native_count = program.native_modules.count(),
            .forbid_native = true,
            .store_count = program.stores.count(),
            .contract_count = program.contracts.count(),
        },
        .program = &validation.input,
        .types = &.{
            .preparation = adapt(@FieldType(TypeRegistration, "preparation"), &type_mapping.input),
            .publication = adapt(@FieldType(TypeRegistration, "publication"), &type_output.target),
        },
        .registration_started = @ptrCast(&marker),
        .registry = &.{
            .source = &keys,
            .buckets = @ptrCast(&registry.buckets.items),
            .capacity = registry.buckets.items.len,
            .identity = initial.identity,
            .version = initial.schema_version,
            .functions = functions,
        },
    };

    const result = plan.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow, error.IntegerOverflow => return if (started[0] == 0) error.OutOfMemory else error.InvalidModule,
        else => return if (started[0] == 0) error.InvalidInitializer else error.InvalidModule,
    };

    return result.*;
}

fn adapt(comptime Target: type, source: anytype) Target {
    return zx.columns.pointer(Target, @as(*const std.meta.Child(@TypeOf(source)), source));
}
