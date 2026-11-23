const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const State = @import("state.zig");
const Finished = @import("finished.zig");
const target = @import("../../call/target.zig");
const Source = frontend.project.artifact.source_link;
const Body = @import("body.zig");
const generated = @import("rx_options").generated_graph;
const Signature = frontend.project.signature_project.Module;
const Parse = frontend.project.ParseCache.ModuleResult;
const ParseHandle = if (generated) @import("rx_execution_abi").layouts.@"zig:rx_project_host".MixedZXParse else anyopaque;
const Binding = std.meta.Child(@FieldType(frontend.ResolvedImports, "imports"));

/// A module ready for analysis: its parse and the functions its imports bind, which the shared tables already hold.
pub const Prepared = struct {
    index: usize,
    source: []const u8,
    parsed: *const frontend.project.ParseCache.ModuleResult,
    type_imports: @FieldType(frontend.ResolvedImports, "aliases"),
    constant_imports: []const zx.ir.Constant,
    imports: []const Binding,
    exports: []const zx.ir.Export,
    constant_exports: []const zx.ir.Constant,
    members: []const Binding,
    /// Whether the parse passed its source checks already, which then come before the imports.
    checked: bool,
};

/// A body analyzed against the shared tables as they stood, with the lengths of the tables then.
pub const Analyzed = struct {
    result: frontend.ResolvedResult,
    functions: usize,
    types: usize,
    native_modules: usize,
    initializers: usize,
    exports: []const zx.ir.Export,
    constant_exports: []const zx.ir.Constant,
    members: []const Binding,
};

pub const Outcome = union(enum) { analyzed: Analyzed, diagnostic: zx.Diagnostic };

pub fn compile(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, index: usize, setter: ?target.Setter, destination: Finished.Destination) State.Error!void {
    state.owner = index;
    _ = state.scratch.reset(.retain_capacity);
    const temporary = state.scratch.allocator();
    var scratch = zx.Arena.init(temporary);

    defer scratch.deinit();

    var work: Serial = .{
        .preparation = .{ .state = state, .allocator = temporary, .cache = cache, .sources = sources, .index = index },
        .scratch = &scratch,
        .setter = setter,
        .destination = destination,
    };

    if (comptime generated) {
        const rule = @import("generated_rx_compile_mixed_zx");
        const input: std.meta.Child(rule.Input) = .{ .body = @ptrCast(&work), .source = @ptrCast(&work.preparation), .setter = setter != null };

        try Body.run(rule, &input);
    } else {
        const parsed = try work.preparation.open();

        try work.preparation.check(parsed);
        try work.preparation.bind(parsed, true);
        if (!try work.run()) return work.report();

        if (setter != null) {
            if (!work.preparation.signature.signature.has_store or work.outcome.analyzed.result.value.ir.stores.count() != 1) return state.fail(.{ .offset = 0, .line = 1, .column = 1 }, "Store setter requires its declared authorized slot");
            try work.installSetter();
        }

        try work.finish();
    }
}

/// Reads the parse of `index` and binds its imports; the shared tables must hold every module it depends on.
pub fn prepare(state: *State, bindings: std.mem.Allocator, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, index: usize, checking: bool) State.Error!Prepared {
    var preparation: Preparation = .{ .state = state, .allocator = bindings, .cache = cache, .sources = sources, .index = index };

    if (comptime generated) {
        const rule = @import("generated_rx_prepare_mixed_zx");
        const input: std.meta.Child(rule.Input) = .{ .source = @ptrCast(&preparation), .check = checking };

        try Body.run(rule, &input);
    } else {
        const parsed = try preparation.open();

        if (checking) try preparation.check(parsed);
        try preparation.bind(parsed, checking);
    }

    return preparation.result;
}

const Preparation = struct {
    state: *State,
    allocator: std.mem.Allocator,
    cache: *frontend.project.ParseCache,
    sources: []const frontend.project.Source,
    index: usize,
    source: []const u8 = undefined,
    signature: Signature = undefined,
    result: Prepared = undefined,
    fn borrow(handle: *const anyopaque) *Preparation {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn open(self: *Preparation) State.Error!*const Parse {
        const state = self.state;
        const index = self.index;
        const path = state.graph.modules.items(.path)[index];

        self.source = self.sources[state.graph.sources.at(index).zx].source;
        self.signature = state.signature(index) orelse return state.fail(.{ .offset = 0, .line = 1, .column = 1 }, "source module signature is missing");

        return self.cache.getModule(self.source, path);
    }
    fn check(self: *Preparation, parsed: *const Parse) State.Error!void {
        if (try parsed.check(self.allocator)) |issue| return diagnostic(self.state, self.source, issue);
    }

    fn bind(self: *Preparation, parsed: *const Parse, checked: bool) State.Error!void {
        const collector = @import("imports.zig");

        const bindings = switch (parsed.*) {
            .native => |result| try collector.collect(self.state, self.allocator, zx.syntax.header.Native{ .program = result.value.parsed.ast }, self.index, self.signature, self.source),
            .indexed => |*result| if (frontend.project.ParseCache.indexed_enabled) try collector.collect(self.state, self.allocator, result.header(), self.index, self.signature, self.source) else unreachable,
        };

        self.result = .{
            .index = self.index,
            .source = self.source,
            .parsed = parsed,
            .type_imports = self.signature.type_imports,
            .constant_imports = self.signature.constant_imports,
            .imports = bindings.functions,
            .exports = self.signature.signature.exports,
            .constant_exports = self.signature.signature.constant_exports,
            .members = bindings.published,
            .checked = checked,
        };
    }
};

const Serial = struct {
    preparation: Preparation,
    scratch: *zx.Arena,
    setter: ?target.Setter,
    destination: Finished.Destination,
    outcome: Outcome = undefined,
    fn borrow(handle: *const anyopaque) *Serial {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn run(self: *Serial) std.mem.Allocator.Error!bool {
        const preparation = &self.preparation;
        const temporary = preparation.allocator;

        const stores: @FieldType(frontend.Context, "stores") = if (self.setter) |grant|
            try temporary.dupe(std.meta.Child(@FieldType(frontend.Context, "stores")), &.{.{ .handle = "$store", .path = grant.name, .type_id = grant.type_id, .readable = false }})

        else
            &.{};

        self.outcome = try analyze(preparation.state, temporary, self.scratch, preparation.result, stores);

        return self.outcome == .analyzed;
    }
    fn report(self: *Serial) State.Error {
        return diagnostic(self.preparation.state, self.preparation.source, self.outcome.diagnostic);
    }
    fn installSetter(self: *Serial) std.mem.Allocator.Error!void {
        const program = &self.outcome.analyzed.result.value.ir;
        const temporary = self.preparation.allocator;
        const paths = try temporary.dupe([]const u8, program.stores.paths);
        paths[0] = try temporary.dupe(u8, self.setter.?.path);
        program.stores.paths = paths;
    }
    fn finish(self: *Serial) State.Error!void {
        try link(self.preparation.state, self.outcome.analyzed, self.destination);
    }
};

pub fn openMixedZXPreparation(handle: *const anyopaque) State.Error!*const ParseHandle {
    return @ptrCast(try Preparation.borrow(handle).open());
}

pub fn checkMixedZXPreparation(handle: *const anyopaque, parsed: *const anyopaque) State.Error!void {
    try Preparation.borrow(handle).check(@ptrCast(@alignCast(parsed)));
}

pub fn bindMixedZXPreparation(handle: *const anyopaque, parsed: *const anyopaque, checked: bool) State.Error!void {
    try Preparation.borrow(handle).bind(@ptrCast(@alignCast(parsed)), checked);
}

pub fn analyzeMixedZXBody(handle: *const anyopaque) std.mem.Allocator.Error!bool {
    return Serial.borrow(handle).run();
}

pub fn reportMixedZXBody(handle: *const anyopaque) State.Error!void {
    return Serial.borrow(handle).report();
}

pub fn mixedZXSetterDeclared(handle: *const anyopaque) bool {
    return Serial.borrow(handle).preparation.signature.signature.has_store;
}

pub fn mixedZXSetterSlots(handle: *const anyopaque) u64 {
    return Serial.borrow(handle).outcome.analyzed.result.value.ir.stores.count();
}

pub fn rejectMixedZXSetter(handle: *const anyopaque, message: []const u8) State.Error!void {
    return Serial.borrow(handle).preparation.state.fail(.{ .offset = 0, .line = 1, .column = 1 }, message);
}

pub fn installMixedZXSetter(handle: *const anyopaque) std.mem.Allocator.Error!void {
    try Serial.borrow(handle).installSetter();
}

pub fn linkMixedZXBody(handle: *const anyopaque) State.Error!void {
    try Serial.borrow(handle).finish();
}

/// Analyzes a prepared body against the shared tables, which it only reads, so bodies that depend on none of each
/// other may run at once.
pub fn analyze(state: *const State, temporary: std.mem.Allocator, scratch: *zx.Arena, prepared: Prepared, stores: @FieldType(frontend.Context, "stores")) std.mem.Allocator.Error!Outcome {
    if (!prepared.checked) if (try prepared.parsed.check(temporary)) |issue| return .{ .diagnostic = issue };

    const base = state.functions.view();

    const result = try frontend.analyzeSharedBody(temporary, prepared.parsed, .{
        .types = state.types.items.view(),
        .nominal_types = state.types.origins.items.view(),
        .native_modules = state.native_modules.view(),
        .stores = stores,
    }, .{
        .aliases = prepared.type_imports,
        .constant_imports = prepared.constant_imports,
        .imports = prepared.imports,
        .functions = base,
        .verified_functions = state.verifiedFunctions(),
        .store_initializers = state.initializers.items,
    }, scratch);

    if (result.value == .diagnostic) return .{ .diagnostic = result.value.diagnostic };

    return .{ .analyzed = .{
        .result = result,
        .functions = base.count(),
        .types = state.types.items.count(),
        .native_modules = state.native_modules.count(),
        .initializers = state.initializers.items.len,
        .exports = prepared.exports,
        .constant_exports = prepared.constant_exports,
        .members = prepared.members,
    } };
}

/// Whether a body analyzed earlier can still be linked as it is: the tables it read may only have gained types and
/// functions, which the type merge and the function prefix account for.
pub fn current(state: *const State, analyzed: Analyzed) bool {
    return @import("body.zig").accept(state, analyzed.native_modules, analyzed.initializers, analyzed.functions, null);
}

/// Links an analyzed body. The tables may have grown, and moved, since the analysis read them, but the rows it read are
/// unchanged, so the body refers to them where they are now.
pub fn link(state: *State, analyzed: Analyzed, destination: Finished.Destination) State.Error!void {
    var program = analyzed.result.value.ir;
    program.native_modules = state.native_modules.view();
    program.exports = analyzed.exports;
    program.constant_exports = analyzed.constant_exports;

    var body: Source.Input = .{
        .program = program,
        .function_suffix = if (analyzed.result.function_suffix) |tail| tail.* else null,
        .nominal_types = analyzed.result.nominal_types,
        .members = analyzed.members,
        .owned_declarations = true,
        .type_suffix = analyzed.result.type_suffix,
    };

    try @import("body/link.zig").publish(state, &body, .{ .functions = analyzed.functions, .types = analyzed.types }, .source, destination);
}

pub fn diagnostic(state: *State, source: []const u8, issue: zx.Diagnostic) State.Error {
    const location = zx.source.locate(source, issue.span.start);

    state.issue = .{
        .path = state.graph.modules.items(.path)[state.owner],
        .location = .{ .offset = issue.span.start, .line = location.line, .column = location.column },
        .code = @tagName(issue.code),
        .message = try state.allocator.dupe(u8, issue.message),
    };

    return error.InvalidSourceGraph;
}
