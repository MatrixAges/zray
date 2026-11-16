const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const State = @import("state.zig");
const Loading = @import("../prepare.zig");
const Inputs = @import("../call_inputs.zig");
const Signature = @import("../signatures.zig").Signature;
const Module = @import("../../module.zig");
const Source = frontend.project.artifact.source_link;
pub const Result = struct { loaded: Source.Loaded, contract: ?Module.Contract };

/// A module ready for lowering: the functions its calls bind, which the shared tables already hold, and the extent of
/// the tables it is lowered against.
pub const Prepared = struct {
    index: usize,
    module: Loading.Module,
    signature: Signature,
    base: ir.FunctionTable,
    calls: []const Module.Loaded,
    functions: usize,
    types: usize,
    native_modules: usize,
    initializers: usize,
};

pub fn compile(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, index: usize, module: Loading.Module, signature: Signature, arguments: Inputs.Module) State.Error!Result {
    state.owner = index;

    const ids = try @import("callees.zig").load(state, state.allocator, cache, sources, module);
    const entry = index == state.graph.entry;

    if (!entry) _ = state.scratch.reset(.retain_capacity);

    const allocator = if (entry) state.allocator else state.scratch.allocator();
    const view = state.functions.view();
    // Only the entry retains its call metadata after linking may move the shared columns.
    const base = if (entry) try view.snapshot(allocator) else view;
    const prepared = try prepare(state, allocator, index, module, signature, ids, arguments, base);
    const result = try lower(state, allocator, prepared);

    if (result == .diagnostic) {
        const copied = try @import("../../call/target.zig").failure(state.allocator, result.diagnostic);

        state.issue = copied.diagnostic;

        return error.InvalidSourceGraph;
    }

    return link(state, prepared, result.contract);
}

/// Binds the calls of `module` to the functions `ids` names, over the shared tables as they stand.
pub fn prepare(state: *State, allocator: std.mem.Allocator, index: usize, module: Loading.Module, signature: Signature, ids: []const ir.FunctionId, arguments: Inputs.Module, base: ir.FunctionTable) State.Error!Prepared {
    const calls = try allocator.alloc(Module.Loaded, module.calls.len);
    const nodes = module.calls.items(.node);
    const inputs = module.calls.items(.input);
    const getters = module.calls.items(.getters);

    for (nodes, inputs, getters, ids, calls, 0..) |node, input, grants, id, *loaded, position| {
        loaded.* = .{
            .node = node,
            .input = input,
            .getters = grants,
            .argument = Inputs.input(arguments, position),
            .function = .{
                .id = id,
                .program = try @import("function.zig").view(state, id, base),
                .nominal_types = state.types.origins.items.view(),
                .store_initializers = state.initializers.items,
            },
        };
    }

    return .{ .index = index, .module = module, .signature = signature, .base = base, .calls = calls, .functions = base.count(), .types = state.types.items.count(), .native_modules = state.native_modules.count(), .initializers = state.initializers.items.len };
}

/// Lowers a prepared module against the shared tables, which it only reads, so modules that depend on none of each
/// other may lower at once.
pub fn lower(state: *const State, allocator: std.mem.Allocator, prepared: Prepared) std.mem.Allocator.Error!Module.Value {
    return @import("../../module_compile.zig").compile(allocator, state.scratch.child_allocator, .{
        .aliases = prepared.module.value_imports,
        .module = prepared.module.source,
        .calls = prepared.calls,
        .plan = prepared.module.plan,
        .bindings = prepared.signature.bindings,
        .tasks = prepared.signature.tasks,
        .types = state.types.items.view(),
        .nominal_types = state.types.origins.items.view(),
        .native_modules = state.native_modules.view(),
        .shared_functions = prepared.base,
        .verified_functions = state.verifiedFunctions(),
        .store_initializers = state.initializers.items,
        .input_type = prepared.signature.input_type,
        .output_type = prepared.signature.output_type,
    });
}

/// Whether a module lowered earlier can still be linked as it is: the tables it read may only have gained types, and
/// functions when it adds none of its own.
pub fn current(state: *const State, prepared: Prepared, contract: Module.Contract) bool {
    const count = contract.program.functions.count() + contract.function_suffix.count();

    return @import("body.zig").accept(state, prepared.native_modules, prepared.initializers, prepared.functions, count);
}

/// Links a lowered module. The tables may have grown, and moved, since it was lowered, but the rows it read are
/// unchanged, so the module refers to them where they are now.
pub fn link(state: *State, prepared: Prepared, lowered: Module.Contract) State.Error!Result {
    const entry = prepared.index == state.graph.entry;
    var contract = lowered;

    if (entry) try @import("metadata.zig").retain(state.allocator, &contract);

    const destination = state.destination();
    const base = state.functions.view().prefix(prepared.functions);
    const plan = @import("body/link.zig").prepare(state, .{ .functions = prepared.functions, .types = prepared.types }, contract.program.functions.count(), true);

    // Without new functions, lowering returns a borrowed view of the analyzed prefix.
    if (plan.replace_prefix) contract.program.functions = base;

    const loaded = state.linked(Source.appendBody(.{
        .program = contract.program,
        .base_functions = base,
        .function_suffix = if (contract.function_suffix.count() != 0) contract.function_suffix else null,
        .verified_functions = state.verifiedFunctions(),
        .nominal_types = contract.nominal_types,
        .store_initializers = contract.store_initializers,
        .shared_initializers = try state.initializersView(),
        .base_types = plan.type_prefix,
    }, destination) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return state.fail(prepared.module.source.node.location, "RX module body cannot be linked to its shared compilation context");
    });

    if (!entry) return .{ .loaded = loaded, .contract = null };

    contract.program = try @import("function.zig").view(state, loaded.function.?, state.functions.view());
    contract.function_suffix = .{};
    contract.types = state.types.items.view();
    contract.nominal_types = state.types.origins.items.view();
    contract.native_modules = state.native_modules.view();
    contract.store_initializers = loaded.store_initializers;

    return .{ .loaded = loaded, .contract = contract };
}
