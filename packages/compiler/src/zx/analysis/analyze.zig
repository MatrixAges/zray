const std = @import("std");
const zx = @import("zx");
const Parsed = @import("../frontend/parse.zig").Parsed;
const HostContext = @import("analyzer/host/context.zig");
const Input = @import("../modules/module_input.zig");
const ModuleResult = @import("../frontend/module_result.zig");
const Origins = @import("../modules/nominal_origins.zig");
const function_body = @import("../modules/function_body.zig");
pub const Resolved = @import("../modules/resolved.zig");

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    restored_payloads: ?zx.Arena = null,
    value: union(enum) { ir: zx.ir.Program, diagnostic: zx.Diagnostic },
    nominal_types: @import("../modules/nominal_origins.zig").Table = .{},
    store_initializers: []const @import("../modules/compiled.zig").StoreInitializer = &.{},
    modules: []const @import("../modules/module_record.zig") = &.{},
    entry_function: ?zx.ir.FunctionId = null,
    public_functions: []const @import("../modules/function_import.zig") = &.{},
    pub fn deinit(self: *Result) void {
        if (self.restored_payloads) |*payloads| payloads.deinit();

        self.arena.deinit();

        self.* = undefined;
    }
};

pub const ResolvedResult = struct {
    value: @FieldType(Result, "value"),
    nominal_types: Origins.Table = .{},
    store_initializers: []const @import("../modules/compiled.zig").StoreInitializer = &.{},
    entry_function: ?zx.ir.FunctionId = null,
    function_suffix: ?*const zx.ir.FunctionTable = null,
    /// Rows added after the borrowed project prefix. References keep their analysis IDs.
    type_suffix: ?zx.ir.TypeTable = null,
};

pub const StoreBinding = struct { handle: []const u8, path: []const u8, type_name: ?[]const u8 = null, type_id: ?zx.ir.TypeId = null, readable: bool = true, writable: bool = true };
pub const Context = struct { types: zx.ir.TypeTable = .{}, nominal_types: Origins.Table = .{}, native_modules: zx.ir.NativeModuleTable = .{}, stores: []const StoreBinding = &.{} };

pub fn analyze(allocator: std.mem.Allocator, parsed: Parsed) std.mem.Allocator.Error!Result {
    return analyzeWithContext(allocator, parsed, .{});
}

pub fn analyzeWithContext(allocator: std.mem.Allocator, parsed: Parsed, context: Context) std.mem.Allocator.Error!Result {
    return analyzeInput(allocator, Input.Native{ .value = parsed }, parsed.file_name, context);
}

pub fn analyzeModule(allocator: std.mem.Allocator, parsed: *const ModuleResult.Result, context: Context) std.mem.Allocator.Error!Result {
    return switch (parsed.*) {
        .native => |result| analyzeWithContext(allocator, result.value.parsed, context),
        .indexed => |*result| if (ModuleResult.indexed_enabled) analyzeInput(allocator, Input.Indexed{ .value = result }, result.file_name, context) else unreachable,
    };
}

pub fn analyzeResolvedIn(allocator: std.mem.Allocator, parsed: *const ModuleResult.Result, context: Context, resolved: Resolved.Input) std.mem.Allocator.Error!ResolvedResult {
    return analyzeResolved(allocator, parsed, context, resolved, null);
}

/// The body borrows scratch until the caller finishes linking it with its signature declarations.
pub fn analyzeSharedBody(allocator: std.mem.Allocator, parsed: *const ModuleResult.Result, context: Context, resolved: Resolved.Input, scratch: *zx.Arena) std.mem.Allocator.Error!ResolvedResult {
    return analyzeResolved(allocator, parsed, context, resolved, if (@import("../ir/validate.zig").internal) null else scratch);
}

fn analyzeResolved(allocator: std.mem.Allocator, parsed: *const ModuleResult.Result, context: Context, resolved: Resolved.Input, scratch: ?*zx.Arena) std.mem.Allocator.Error!ResolvedResult {
    return switch (parsed.*) {
        .native => |result| analyzeInputIn(allocator, Input.Native{ .value = result.value.parsed }, result.value.parsed.file_name, context, resolved, null),
        .indexed => |*result| if (ModuleResult.indexed_enabled) analyzeInputIn(allocator, Input.Indexed{ .value = result }, result.file_name, context, resolved, scratch) else unreachable,
    };
}

fn analyzeInput(allocator: std.mem.Allocator, input: anytype, file_name: []const u8, context: Context) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const result = try analyzeInputIn(arena.allocator(), input, file_name, context, null, null);

    return .{ .arena = arena, .value = result.value, .nominal_types = result.nominal_types, .store_initializers = result.store_initializers, .entry_function = result.entry_function };
}

fn analyzeInputIn(allocator: std.mem.Allocator, input: anytype, file_name: []const u8, context: Context, resolved: ?Resolved.Input, scratch: ?*zx.Arena) std.mem.Allocator.Error!ResolvedResult {
    var reporter: zx.Reporter = .{};
    var copied_types: zx.ir.TypeStorage = .{};
    var origins = Origins{ .allocator = allocator };
    const functions = if (resolved) |bindings| bindings.functions else zx.ir.FunctionTable{};
    // A resolved context is the project's shared tables, built only from linked modules that passed validation
    // and kept alive past this analysis; internal builds still re-check them.
    const trusted = resolved != null and !@import("../ir/validate.zig").internal;

    if (!@TypeOf(input).completes_ownership) {
        const header = input.header();

        if (resolved == null and header.importCount() > 0) return .{ .value = .{ .diagnostic = .{ .code = .module, .span = header.importAt(0).span, .message = "modules with imports require the project analysis entry point" } } };

        if (!trusted and context.types.count() != 0 and !@import("../ir/type_rules.zig").validate(context.types)) return .{ .value = .{ .diagnostic = .{
            .code = .contract,
            .span = .{ .start = 0, .end = 0 },
            .message = "invalid shared type table",
        } } };

        if (!trusted and !@import("../modules/native_context.zig").valid(context.types, context.native_modules)) return .{ .value = .{ .diagnostic = .{
            .code = .contract,
            .span = .{ .start = 0, .end = 0 },
            .message = "invalid shared native module table",
        } } };

        if (resolved) |bindings| {
            if (!Resolved.valid(header, bindings, context.types)) return .{ .value = .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "resolved imports do not match the source declarations and function signatures" } } };
        }

        copied_types = if (resolved != null) try @import("type_table.zig").columns(allocator, context.types) else try @import("type_table.zig").storage(allocator, context.types);

        if (trusted) try origins.borrow(copied_types.view(), context.nominal_types) else origins.seed(copied_types.view(), context.nominal_types) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return .{ .value = .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "invalid shared nominal type table" } } };
        };
    }

    var analyzer = HostContext{
        .allocator = allocator,
        .mode = if (resolved != null) .resolved else .standalone,
        .body_scratch = scratch,
        .base_types = context.types,
        .base_origins = context.nominal_types,
        .native_modules = context.native_modules,
        .store_bindings = context.stores,
        .store_type_count = context.types.count(),
        .reporter = &reporter,
        .functions = functions,
        .function_imports = if (resolved) |bindings| bindings.imports else &.{},
        .constant_imports = if (resolved) |bindings| bindings.constant_imports else &.{},
        .types = &copied_types,
        .aliases = if (resolved) |bindings| bindings.aliases else &.{},
        .origins = &origins,
        .origin = .{ .source = file_name },
    };

    var program = input.analyze(&analyzer, file_name) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .value = .{ .diagnostic = reporter.diagnostic.? } };
    };

    const declared = input.header().functionName() != null;

    if (comptime @TypeOf(input).completes_ownership) {
        program.functions = functions;
        program.native_modules = context.native_modules;

        const initializers = if (resolved) |bindings| bindings.store_initializers else &.{};
        const entry = try @import("publication/entry/host.zig").finish(allocator, &program, if (resolved) |*bindings| bindings else null, declared, initializers);

        if (entry.issue) |issue| return .{ .value = .{ .diagnostic = issue } };

        return .{
            .value = .{ .ir = program },
            .nominal_types = origins.items.view(),
            .store_initializers = initializers,
            .entry_function = entry.entry,
            .function_suffix = entry.suffix,
            .type_suffix = if (scratch != null) copied_types.view() else null,
        };
    }

    return finishSeed(allocator, &program, declared, context, if (resolved) |*bindings| bindings else null, origins.items.view(), &reporter);
}

fn finishSeed(allocator: std.mem.Allocator, program: *zx.ir.Program, declared: bool, context: Context, resolved: ?*const Resolved.Input, origins: Origins.Table, reporter: *zx.Reporter) std.mem.Allocator.Error!ResolvedResult {
    const functions = if (resolved) |bindings| bindings.functions else zx.ir.FunctionTable{};
    const recursive = try function_body.completeSeed(allocator, program, functions, declared);

    program.native_modules = if (resolved != null) context.native_modules else try @import("../modules/native_context.zig").copy(allocator, context.native_modules);

    program.output_ownership = @import("../ownership/check.zig").analyze(allocator, program.*, reporter) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .value = .{ .diagnostic = reporter.diagnostic.? } };
    };

    if (recursive != null) {
        const ownership = try allocator.dupe(std.meta.Child(@TypeOf(program.functions.ownership)), program.functions.ownership);

        ownership[functions.count()] = switch (program.output_ownership) {
            .copy => .Copy,
            .borrowed => .Borrowed,
            .owned => .Owned,
        };

        program.functions.ownership = ownership;
    }

    if (resolved) |bindings| {
        if (@import("../ir/validate.zig").internal) if (try @import("../ir/validate.zig").validateExtending(allocator, program.*, bindings.verified_functions)) |issue| return .{ .value = .{ .diagnostic = issue } };
    }

    const initializers = if (resolved) |bindings| bindings.store_initializers else &.{};

    for (initializers) |initializer| {
        if (@backingInt(initializer.function) >= functions.count()) return .{ .value = .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "resolved Store initializer references a missing function" } } };
    }

    var entry_function: ?zx.ir.FunctionId = null;
    var function_suffix: ?*const zx.ir.FunctionTable = null;

    if (recursive) |id| {
        if (resolved != null) {
            const tail = try allocator.create(zx.ir.FunctionTable);

            tail.* = program.functions.suffix(functions.count());
            program.functions = functions;
            function_suffix = tail;
        } else if (std.meta.eql(function_body.value(program.*), program.functions.at(@backingInt(id)))) {
            // Seed ownership analysis can change the program after the recursive body was installed.
            try function_body.entry(allocator, program, id);

            entry_function = id;
        }
    }

    return .{ .value = .{ .ir = program.* }, .nominal_types = origins, .store_initializers = initializers, .entry_function = entry_function, .function_suffix = function_suffix };
}
