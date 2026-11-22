const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const context = @import("context.zig");
const entry = @import("generated_function_context_scope");
const body = @import("generated_function_context_body");
const Rule = @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload;

pub inline fn inherit(parent: *Lower, comptime form: entry.Input) Lower {
    const scope = comptime rule(form);

    return .{
        .allocator = parent.allocator,
        .workspace = parent.workspace,
        .program = parent.program,
        .entry_flags = parent.entry_flags,
        .self_function = parent.self_function,
        .builder = parent.builder,
        .types = parent.types,
        .layouts = parent.layouts,
        .abi_types = parent.abi_types,
        .abi_layouts = parent.abi_layouts,
        .state_types = parent.state_types,
        .state_layouts = parent.state_layouts,
        .view_types = parent.view_types,
        .type_scratch = parent.type_scratch,
        .state_plan = parent.state_plan,
        .state_active = scope.representation and parent.state_active,
        .deferred_lists = parent.deferred_lists,
        .state_symbols = switch (scope.members) {
            .Empty => .empty,
            .Borrow => parent.state_symbols.inherit(),
            .Keep => parent.state_symbols,
        },
        .names = if (scope.names == .Borrow) parent.names else &.{},
        .native_names = parent.native_names,
        .used = parent.used,
        .cache_reads = parent.cache_reads,
        .cache = if (scope.cache) parent.cache else .empty,
        .plans = parent.plans,
        .plan = parent.plan,
        .serial = if (scope.serial) parent.serial else 0,
        .capture = if (scope.locals) parent.capture else null,
        .uses_allocator = scope.local_effects and parent.uses_allocator,
        .allows_allocation = parent.allows_allocation,
        .uses_io = scope.local_effects and parent.uses_io,
        .uses_process = scope.process and parent.uses_process,
        .io_functions = parent.io_functions,
        .process_functions = parent.process_functions,
        .task_functions = parent.task_functions,
        .value_functions = parent.value_functions,
        .function_errors = parent.function_errors,
        .error_cache = parent.error_cache,
        .pure_functions = parent.pure_functions,
        .identity_free_functions = parent.identity_free_functions,
        .local_functions = parent.local_functions,
        .fresh_outputs = parent.fresh_outputs,
        .constructed_outputs = parent.constructed_outputs,
        .value_output = scope.representation and parent.value_output,
        .public_value_output = scope.representation and parent.public_value_output,
        .stack_symbols = if (scope.cache) parent.stack_symbols else .empty,
        .reference_storage = if (scope.references) parent.reference_storage else .empty,
        .projected_symbols = parent.projected_symbols,
        .input_aliases = parent.input_aliases,
        .iteration_value = if (scope.locals) parent.iteration_value else null,
        .loop_fields = if (scope.loop_fields) parent.loop_fields else null,
        .layout_types = parent.layout_types,
        .slot_counts = parent.slot_counts,
        .growth_functions = parent.growth_functions,
        .may_grow = parent.may_grow,
        .uses_context = parent.uses_context,
        .uses_parallel = parent.uses_parallel,
        .shared_types = parent.shared_types,
        .pending_name = parent.pending_name,
        .type_names = parent.type_names,
        .function_modules = parent.function_modules,
        .local_regular_function = parent.local_regular_function,
        .function_requests = parent.function_requests,
        .comparisons = parent.comparisons,
        .task_declarations = parent.task_declarations,
    };
}

pub fn reserve(self: *Lower, allocator: std.mem.Allocator, comptime form: entry.Input) Lower.Error!void {
    const scope = comptime rule(form);
    const symbols = if (scope.names == .Input) 1 else self.used.len;
    const expressions = if (scope.names == .Input) self.program.expressions.count() else self.cache_reads.len;

    try context.allocate(self, allocator, @fromBackingInt(@backingInt(scope.names)), symbols, expressions);
    try context.clear(self);
}

pub fn installPredicate(program: *ir.Program, predicates: *const ir.ContractTable, index: usize) void {
    inline for (comptime zx.staticSequence(body, .Predicate)) |field| {
        switch (field) {
            .Symbols => program.symbols = predicates.symbols[index].*,
            .Expressions => program.expressions = predicates.expressions[index].*,
            else => @compileError("Predicate scope can only install symbol and expression columns"),
        }
    }
}

pub fn installFunction(program: *ir.Program, index: usize, comptime form: body.Input) void {
    const functions = &program.functions;

    inline for (comptime zx.staticSequence(body, form)) |field| {
        switch (field) {
            .Symbols => program.symbols = functions.symbols[index].*,
            .Expressions => program.expressions = functions.expressions[index].*,
            .Body => program.body = functions.controlAt(index),
            .InputType => program.input_type = @fromBackingInt(functions.input_types[index]),
            .OutputType => program.output_type = @fromBackingInt(functions.output_types[index]),
            .Stores => program.stores = functions.stores[index].*,
            .StoreMode => program.store_mode = functions.store_modes[index],
            .Contracts => program.contracts = functions.contracts[index].*,
        }
    }
}

pub inline fn publish(parent: *Lower, child: *const Lower, comptime form: entry.Input) void {
    const flags = comptime rule(form).publish;
    const entry_effects = @import("generated_function_scope_effects");
    const Input = std.meta.Child(entry_effects.Input);
    const Effects = std.meta.Child(@FieldType(Input, "parent"));

    const before: Effects = .{
        .input = flags.input and parent.used[0],
        .uses_allocator = parent.uses_allocator,
        .uses_io = parent.uses_io,
        .uses_parallel = parent.uses_parallel,
    };

    const after: Effects = .{
        .input = flags.input and child.used[0],
        .uses_allocator = child.uses_allocator,
        .uses_io = child.uses_io,
        .uses_parallel = child.uses_parallel,
    };

    const enabled: Effects = .{
        .input = flags.input,
        .uses_allocator = flags.uses_allocator,
        .uses_io = flags.uses_io,
        .uses_parallel = flags.uses_parallel,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const request: Input = .{ .parent = &before, .child = &after, .publish = &enabled };
    const result = zx.columns.invoke(entry_effects.executeValue, fixed.allocator(), &request) catch unreachable;

    if (flags.uses_allocator) parent.uses_allocator = result.uses_allocator;
    if (flags.uses_io) parent.uses_io = result.uses_io;
    if (flags.uses_parallel) parent.uses_parallel = result.uses_parallel;
    if (flags.input) parent.used[0] = result.input;
    if (flags.serial) parent.serial = child.serial;
    if (flags.references) parent.reference_storage = child.reference_storage;
}

fn rule(comptime form: entry.Input) Rule {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeValue(fixed.allocator(), form) catch unreachable;
}
