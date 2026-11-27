const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Types = @import("../types.zig");
const Origins = @import("../../nominal_origins.zig");
const Registry = @import("../../compiled/initializer_registry.zig");
const Initializer = @import("../../source_store_initializer.zig");
const Nodes = @import("../../artifact/nodes.zig");
const publication = @import("../source/workflow/host.zig");
const comparison = @import("../../../ir/compare/initializer.zig");
const merge = @import("../../../analysis/semantic/merge.zig");
const plan = @import("generated_source_initializer_prepare");
const StoreState = std.meta.Child(@FieldType(plan.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

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

    try publication.append(&nodes, functions, initial.program, temporary, &.{
        .identity = initial.identity,
        .version = initial.schema_version,
        .function = selected.function,
    }, registry);
}

fn prepare(types: *Types, temporary: std.mem.Allocator, functions: usize, registry: *Registry, initial: Initializer.Borrowed, origins: Origins.Table, mapping: *[]u32) Error!std.meta.Child(plan.Output) {
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

    var view: merge.Registration = undefined;

    view.init(&request, mapping);
    errdefer view.output.release();

    const rows = Registry.readRows(registry.rows.items);
    const keys = rows.bind(std.meta.Child(@FieldType(Lookup, "source")));
    var state_value: std.meta.Child(StoreState) = .{ .started = false };
    var state_ptr: StoreState = &state_value;
    var host: StoreHost = .{ .store_0 = &state_ptr };

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
        .types = &view.bind(TypeRegistration),
        .registry = &.{
            .source = &keys,
            .buckets = @ptrCast(&registry.buckets),
            .capacity = registry.buckets.len,
            .identity = initial.identity,
            .version = initial.schema_version,
            .functions = functions,
        },
    };

    const result = plan.executeIn(temporary, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow, error.IntegerOverflow => return if (!state_ptr.started) error.OutOfMemory else error.InvalidModule,
        else => return if (!state_ptr.started) error.InvalidInitializer else error.InvalidModule,
    };

    return result.*;
}
