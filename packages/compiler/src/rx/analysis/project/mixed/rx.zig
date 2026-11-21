const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const State = @import("state.zig");
const Loading = @import("../prepare.zig");
const Inputs = @import("../call_inputs.zig");
const Signature = @import("../signatures.zig").Signature;
const Compilation = @import("../../module_compile.zig");
const Source = frontend.project.artifact.source_link;
pub const Result = struct { loaded: Source.Loaded, metadata: ?*Compilation.Metadata };

/// A module ready for lowering: the functions its calls bind, which the shared tables already hold, and the extent of
/// the tables it is lowered against.
pub const Prepared = struct {
    index: usize,
    module: Loading.Module,
    signature: Signature,
    base: ir.FunctionTable,
    ids: []const ir.FunctionId,
    arguments: Inputs.Module,
    functions: usize,
    types: usize,
    native_modules: usize,
    initializers: usize,
};

pub fn compile(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, index: usize, module: Loading.Module, signature: Signature, arguments: Inputs.Module) State.Error!Result {
    state.owner = index;
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var temporary = std.heap.BufferFirstAllocator.init(&buffer, state.scratch.child_allocator);
    const ids = try @import("callees.zig").load(state, temporary.allocator(), cache, sources, module);

    defer temporary.allocator().free(ids);

    const entry = index == state.graph.entry;

    if (!entry) _ = state.scratch.reset(.retain_capacity);

    const allocator = if (entry) state.allocator else state.scratch.allocator();
    const prepared = try prepare(state, index, module, signature, ids, arguments, state.functions.view());
    const result = try lower(state, allocator, prepared);

    if (result == .diagnostic) {
        const copied = try @import("../../call/target.zig").failure(state.allocator, result.diagnostic);

        state.issue = copied.diagnostic;

        return error.InvalidSourceGraph;
    }

    return link(state, prepared, result.body);
}

/// Binds the calls of `module` to the functions `ids` names, over the shared tables as they stand.
pub fn prepare(state: *State, index: usize, module: Loading.Module, signature: Signature, ids: []const ir.FunctionId, arguments: Inputs.Module, base: ir.FunctionTable) State.Error!Prepared {
    if (!@import("function.zig").admitted(ids, base.count())) return state.fail(.{ .offset = 0, .line = 1, .column = 1 }, "resolved function is outside the shared function table");

    return .{ .index = index, .module = module, .signature = signature, .base = base, .ids = ids, .arguments = arguments, .functions = base.count(), .types = state.types.items.count(), .native_modules = state.native_modules.count(), .initializers = state.initializers.items.len };
}

/// Lowers a prepared module against the shared tables, which it only reads, so modules that depend on none of each
/// other may lower at once.
pub fn lower(state: *const State, allocator: std.mem.Allocator, prepared: Prepared) std.mem.Allocator.Error!Compilation.Value {
    return Compilation.compile(allocator, state.scratch.child_allocator, .{
        .entry = prepared.index == state.graph.entry,
        .aliases = prepared.module.value_imports,
        .module = prepared.module.source,
        .calls = prepared.module.calls,
        .ids = prepared.ids,
        .arguments = prepared.arguments,
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
pub fn current(state: *const State, prepared: Prepared, body: Compilation.Body) bool {
    const count = body.lowered.program.functions.count() + body.lowered.function_suffix.count();

    return @import("body.zig").accept(state, prepared.native_modules, prepared.initializers, prepared.functions, count);
}

/// Links a lowered module. The tables may have grown, and moved, since it was lowered, but the rows it read are
/// unchanged, so the module refers to them where they are now.
pub fn link(state: *State, prepared: Prepared, body: Compilation.Body) State.Error!Result {
    var program = body.lowered.program;
    const destination = state.destination();
    const base = state.functions.view().prefix(prepared.functions);
    const plan = @import("body/link.zig").prepare(state, .{ .functions = prepared.functions, .types = prepared.types }, program.functions.count());

    // Without new functions, lowering returns a borrowed view of the analyzed prefix.
    if (plan.replace_prefix) program.functions = base;

    const loaded = state.linked(Source.appendBody(.{
        .program = program,
        .base_functions = base,
        .function_suffix = if (body.lowered.function_suffix.count() != 0) body.lowered.function_suffix else null,
        .verified_functions = state.verifiedFunctions(),
        .nominal_types = body.nominal_types,
        .store_initializers = body.lowered.store_initializers,
        .shared_initializers = try state.initializersView(),
        .base_types = plan.type_prefix,
    }, destination) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return state.fail(prepared.module.source.node.location, "RX module body cannot be linked to its shared compilation context");
    });

    return .{ .loaded = loaded, .metadata = body.metadata };
}
