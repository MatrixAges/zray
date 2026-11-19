const std = @import("std");
const Analysis = @import("frontend").AnalysisResult;
const generating = @import("genz").zx.modules;
const names = @import("names.zig");
const references = @import("genz").zx.references;
const fingerprint = @import("fingerprint.zig");
pub const Batch = @import("batch.zig");
const Cache = @import("cache.zig");
pub const Error = names.Error || generating.Error || error{ InvalidAnalysis, ConflictingFunction };

pub const File = struct {
    imports: []const []const u8,
    name: []const u8,
    source: []const u8,
    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try writer.write(.{ .name = self.name, .source = self.source, .imports = self.imports });
    }
};

pub const StoreInitializer = struct { identity: []const u8, schema_version: u32, module_name: []const u8, type_name: []const u8 };
pub const Signature = struct { types: @import("zx").ir.TypeTable, input: @import("zx").ir.TypeId, output: @import("zx").ir.TypeId };

pub const Bundle = struct {
    arena: std.heap.ArenaAllocator,
    entry: File,
    types: []const u8,
    modules: []const File,
    type_names: []const []const u8 = &.{},
    native_modules: @import("zx").ir.NativeModuleTable = .{},
    store_initializers: []const StoreInitializer = &.{},
    state_module: ?[]const u8 = null,
    requirements: ?@import("genz").zx.state.Requirements = null,
    runner: ?[]const u8 = null,
    signature: ?Signature = null,
    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn create(allocator: std.mem.Allocator, analysis: *const Analysis) Error!Bundle {
    return createCached(allocator, analysis, null);
}

pub fn createCached(allocator: std.mem.Allocator, analysis: *const Analysis, cache: ?*Cache) Error!Bundle {
    if (analysis.value != .ir) return error.InvalidAnalysis;

    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const owned = arena.allocator();
    const program = try @import("genz").zx.prepareWithWorkspace(owned, allocator, analysis.value.ir);

    var batch = batch: {
        var facts = try generating.Analysis.create(allocator, program);

        errdefer facts.deinit();

        const identities = try names.createWith(owned, allocator, program, analysis.nominal_types, .{
            .io = facts.value.io,
            .process = facts.value.process,
        });

        break :batch Batch.fromAnalysis(allocator, program, identities, cache, facts);
    };

    defer batch.deinit();

    const identities = batch.names;
    const graph = try references.plan(allocator, allocator, program.functions, &.{&program}, &.{});

    defer allocator.free(graph.needed);

    const entry = File{ .name = "application", .source = try batch.emit(owned, .entry), .imports = try references.imports(owned, allocator, program.expressions, program.contracts, identities.functions, &.{}) };
    const native_modules = try nativeModules(owned, program);
    const modules = try functionFilesPlanned(owned, &batch, graph, &.{entry.source}, native_modules.import_names);
    const type_source = try batch.emit(owned, .types);
    const type_names = try typeNamesAnalyzed(owned, batch.backing, program, identities, batch.analysis.value.value.state);

    const signature = Signature{
        .types = try @import("frontend").type_table.copy(owned, program.types),
        .input = program.input_type,
        .output = program.output_type,
    };

    const flags = batch.analysis.value.entry_flags;

    return .{ .requirements = .{ .io = flags.io, .process = flags.process }, .arena = arena, .entry = entry, .types = type_source, .modules = modules, .type_names = type_names, .native_modules = native_modules, .signature = signature };
}

pub fn emit(allocator: std.mem.Allocator, program: @import("zx").ir.Program, identities: generating.Names, unit: fingerprint.Unit, cache: ?*Cache) Error![]const u8 {
    return emitBacked(allocator, allocator, program, identities, unit, cache);
}

pub fn emitBacked(output: std.mem.Allocator, backing: std.mem.Allocator, program: @import("zx").ir.Program, identities: generating.Names, unit: fingerprint.Unit, cache: ?*Cache) Error![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const prepared = try @import("genz").zx.prepareWithWorkspace(scratch.allocator(), backing, program);
    var batch = try Batch.create(backing, prepared, identities, cache);

    defer batch.deinit();

    return batch.emit(output, unit);
}

pub fn emitPrepared(allocator: std.mem.Allocator, program: @import("zx").ir.Program, identities: generating.Names, unit: fingerprint.Unit, cache: ?*Cache) Error![]const u8 {
    var batch = try Batch.create(allocator, program, identities, cache);

    defer batch.deinit();

    return batch.emit(allocator, unit);
}

/// The files of the `needed` functions; `roots` are the other generated sources that call into them.
pub fn functionFilesAnalyzed(owned: std.mem.Allocator, batch: *const Batch, needed: []const bool, roots: []const []const u8, native_names: []const []const u8) Error![]const File {
    return functionFilesPlanned(owned, batch, .{ .needed = needed, .count = std.mem.countScalar(bool, needed, true) }, roots, native_names);
}

fn functionFilesPlanned(owned: std.mem.Allocator, batch: *const Batch, graph: references.Reachability, roots: []const []const u8, native_names: []const []const u8) Error![]const File {
    const units = try @import("function_units.zig").create(batch.backing, graph, &.{});

    defer batch.backing.free(units);

    const sources = try @import("function_sources.zig").createJobs(owned, .{ .batch = batch, .functions = units });

    return functionFilesFrom(owned, batch, units, sources, roots, native_names);
}

/// The files of function `units` from their generated `sources`, once the `roots` that call them are known.
pub fn functionFilesFrom(owned: std.mem.Allocator, batch: *const Batch, units: []generating.FunctionUnit, sources: [][]const u8, roots: []const []const u8, native_names: []const []const u8) Error![]const File {
    if (comptime !@import("parser_options").generated_parser) return @import("function_files_seed.zig").create(owned, batch, units, sources, roots);
    try @import("regular_calls.zig").complete(owned, batch, roots, units, sources);

    var scratch = std.heap.ArenaAllocator.init(batch.backing);

    defer scratch.deinit();

    const registry = @import("function_files.zig");
    const names_for_files = batch.names.functions;
    const selected = try registry.select(scratch.allocator(), names_for_files, units, sources);
    const files = try owned.alloc(File, selected.len);

    for (selected, files) |position, *file| {
        const row: usize = @intCast(position);
        const index = @backingInt(units[row].id);

        file.* = .{
            .name = names_for_files[index],
            .source = sources[row],
            .imports = try references.fileImports(owned, batch.backing, &batch.program.functions, index, names_for_files, native_names),
        };
    }

    return files;
}

pub fn typeNames(owned: std.mem.Allocator, program: @import("zx").ir.Program, identities: generating.Names) std.mem.Allocator.Error![]const []const u8 {
    const state_plan = try @import("genz").zx.state_value.Analysis.create(owned, program);

    defer owned.free(state_plan.selected);
    defer owned.free(state_plan.borrowed);
    defer owned.free(state_plan.keys);
    defer owned.free(state_plan.queries);

    return typeNamesAnalyzed(owned, owned, program, identities, state_plan);
}

pub fn typeNamesAnalyzed(owned: std.mem.Allocator, workspace: std.mem.Allocator, program: @import("zx").ir.Program, identities: generating.Names, state_plan: @import("genz").zx.state_value.Analysis) std.mem.Allocator.Error![]const []const u8 {
    return generating.typeNames(owned, workspace, program, identities.types, state_plan);
}

pub fn nativeModules(owned: std.mem.Allocator, program: @import("zx").ir.Program) std.mem.Allocator.Error!@import("zx").ir.NativeModuleTable {
    const ir = @import("zx").ir;
    var native_modules: ir.NativeModuleStorage = .{};

    errdefer native_modules.deinit(owned);

    for (0..program.native_modules.count()) |index| {
        const module = program.native_modules.at(index);

        try native_modules.append(owned, .{
            .specifier = try owned.dupe(u8, module.specifier),
            .identity = if (module.identity) |identity| try owned.dupe(u8, identity) else null,
            .import_name = try owned.dupe(u8, module.import_name),
        });
    }

    return native_modules.finish(owned);
}
