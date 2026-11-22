const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const State = @import("state.zig");
const Loading = @import("../prepare.zig");
const Inputs = @import("../call_inputs.zig");
const Signature = @import("../signatures.zig").Signature;
const Compilation = @import("../../module_compile.zig");
const Source = frontend.project.artifact.source_link;
const Body = @import("body.zig");
const generated = @import("rx_options").generated_graph;
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

    var work: Serial = .{
        .state = state,
        .cache = cache,
        .sources = sources,
        .index = index,
        .module = module,
        .signature = signature,
        .arguments = arguments,
        .temporary = temporary.allocator(),
    };

    defer if (work.ids) |ids| work.temporary.free(ids);

    if (comptime generated) {
        const rule = @import("generated_rx_compile_mixed_rx");
        const input: std.meta.Child(rule.Input) = .{ .body = @ptrCast(&work), .index = index, .entry = state.graph.entry };

        try Body.run(rule, &input);
    } else {
        try work.bind();
        if (!try work.run(index == state.graph.entry)) return work.report();
        try work.finish();
    }

    return work.linked;
}

const Serial = struct {
    state: *State,
    cache: *frontend.project.ParseCache,
    sources: []const frontend.project.Source,
    index: usize,
    module: Loading.Module,
    signature: Signature,
    arguments: Inputs.Module,
    temporary: std.mem.Allocator,
    ids: ?[]const ir.FunctionId = null,
    prepared: Prepared = undefined,
    result: Compilation.Value = undefined,
    linked: Result = undefined,
    fn borrow(handle: *const anyopaque) *Serial {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn bind(self: *Serial) State.Error!void {
        self.ids = try @import("callees.zig").load(self.state, self.temporary, self.cache, self.sources, self.module);
    }

    fn run(self: *Serial, entry: bool) State.Error!bool {
        const state = self.state;

        if (!entry) _ = state.scratch.reset(.retain_capacity);

        const allocator = if (entry) state.allocator else state.scratch.allocator();

        self.prepared = try prepare(state, self.index, self.module, self.signature, self.ids.?, self.arguments, state.functions.view());
        self.result = try lower(state, allocator, self.prepared);

        return self.result == .body;
    }

    fn report(self: *Serial) State.Error {
        const copied = try @import("../../call/target.zig").failure(self.state.allocator, self.result.diagnostic);

        self.state.issue = copied.diagnostic;

        return error.InvalidSourceGraph;
    }

    fn finish(self: *Serial) State.Error!void {
        self.linked = try link(self.state, self.prepared, self.result.body);
    }
};

pub fn bindMixedRXBody(handle: *const anyopaque) State.Error!void {
    try Serial.borrow(handle).bind();
}

pub fn lowerMixedRXBody(handle: *const anyopaque, entry: bool) State.Error!bool {
    return Serial.borrow(handle).run(entry);
}

pub fn reportMixedRXBody(handle: *const anyopaque) State.Error!void {
    return Serial.borrow(handle).report();
}

pub fn linkMixedRXBody(handle: *const anyopaque) State.Error!void {
    try Serial.borrow(handle).finish();
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
    var input: Source.Input = .{
        .program = body.lowered.program,
        .function_suffix = if (body.lowered.function_suffix.count() != 0) body.lowered.function_suffix else null,
        .nominal_types = body.nominal_types,
        .store_initializers = body.lowered.store_initializers,
    };

    const loaded = try @import("body/link.zig").publish(state, &input, .{ .functions = prepared.functions, .types = prepared.types }, .{ .flow = prepared.module.source.node.location });

    return .{ .loaded = loaded, .metadata = body.metadata };
}
