const std = @import("std");
const model = @import("../../library/root.zig");
const validation = @import("../../library/validate.zig");
const modules = @import("modules.zig");
const names = @import("names.zig");
const references = @import("genz").zx.references;
const Cache = @import("cache.zig");
pub const Error = modules.Error || validation.Error || error{InvalidModule};

pub const PublicModule = struct {
    name: []const u8,
    file: modules.File,
    value_entry: bool = false,
    state_entry: bool = false,
    allocator_entry: bool = false,
    constant_only: bool = false,
    requires_io: ?bool = null,
    requires_process: bool = false,
};

pub const Options = struct { signatures: bool = false };

pub const Bundle = struct {
    arena: std.heap.ArenaAllocator,
    public_modules: []const PublicModule,
    types: []const u8,
    signatures: ?[]const u8 = null,
    modules: []const modules.File,
    type_names: []const []const u8,
    native_modules: @import("zx").ir.NativeModuleTable,
    store_initializers: []const modules.StoreInitializer = &.{},
    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn createCached(allocator: std.mem.Allocator, library: *const model.Result, cache: ?*Cache) Error!Bundle {
    return create(allocator, allocator, library, cache, false, false, .{});
}

/// A bundle of files that import each other, held in memory from `output`; what building it needs only meanwhile
/// comes from `allocator`.
pub fn createFilesCached(allocator: std.mem.Allocator, output: std.mem.Allocator, library: *const model.Result, cache: ?*Cache) Error!Bundle {
    return create(allocator, output, library, cache, true, false, .{});
}

pub fn createFilesCachedConcurrent(allocator: std.mem.Allocator, output: std.mem.Allocator, library: *const model.Result, cache: ?*Cache) Error!Bundle {
    return createFilesCachedConcurrentWith(allocator, output, library, cache, .{});
}

pub fn createFilesCachedConcurrentWith(allocator: std.mem.Allocator, output: std.mem.Allocator, library: *const model.Result, cache: ?*Cache, options: Options) Error!Bundle {
    return create(allocator, output, library, cache, true, true, options);
}

fn create(allocator: std.mem.Allocator, output: std.mem.Allocator, library: *const model.Result, cache: ?*Cache, file_imports: bool, comptime concurrent_analysis: bool, options: Options) Error!Bundle {
    if (@import("frontend").checks_internal_ir) {
        try validation.validate(allocator, library);
    } else {
        try validation.validateHeader(library);
    }

    var arena = std.heap.ArenaAllocator.init(output);

    errdefer arena.deinit();

    var publication_arena = std.heap.ArenaAllocator.init(allocator);

    defer publication_arena.deinit();

    const owned = arena.allocator();
    const workspace = publication_arena.allocator();
    const program = try @import("genz").zx.prepareWithWorkspace(owned, allocator, library.program);
    const publication = try @import("library_publication.zig").create(workspace, library.exports, program.functions.count());
    const memos = @import("uniqueness_memo.zig");
    const keeps_memo = if (cache) |store| store.keeps_memo else false;
    var loaded = if (keeps_memo) null else try memos.load(allocator, cache);

    defer if (loaded) |*value| value.deinit();

    const memo = if (loaded) |*value| value else if (keeps_memo) try cache.?.keepMemo() else null;
    const Analysis = @import("genz").zx.modules.Analysis;

    var batch = initialized: {
        var analysis = if (concurrent_analysis)
            try Analysis.createRememberedConcurrent(allocator, program, publication.roots, memo)
        else
            try Analysis.createRemembered(allocator, program, publication.roots, memo);

        errdefer analysis.deinit();

        // Use the capabilities already discovered by the analysis.
        var identities = try names.createWith(owned, allocator, program, library.nominal_types, .{ .io = analysis.value.io, .process = analysis.value.process });

        if (file_imports) identities.functions = try @import("library_publication.zig").fileNames(owned, identities.functions);

        break :initialized modules.Batch.fromAnalysis(allocator, program, identities, cache, analysis);
    };

    const identities = batch.names;

    defer batch.deinit();

    if (loaded) |*value| try memos.save(allocator, cache, value);

    var prepared_library = library.*;
    prepared_library.program = program;

    const entries = try @import("library_entries.zig").create(owned, workspace, &prepared_library, &batch, publication, file_imports);
    const public_modules = entries.modules;
    const public_batches = entries.batches;
    const graph = try references.plan(workspace, allocator, program.functions, entries.roots, publication.member_ids);
    const units = try @import("function_units.zig").create(workspace, graph, publication.regular);
    const generated = try @import("function_sources.zig").createJobs(owned, .{ .batch = &batch, .entries = public_batches, .types = true, .functions = units });
    @import("library_publication.zig").complete(library.exports, program.type_only, public_modules, generated[0..public_batches.len]);

    const type_source = generated[public_batches.len];
    const initializers = try @import("library_initializers.zig").createBacked(owned, allocator, library, identities, cache);
    const native_modules = try modules.nativeModules(owned, program);
    const files = try modules.functionFilesFrom(owned, &batch, units, generated[public_batches.len + 1 ..], generated[0..public_batches.len], native_modules.import_names, initializers.files);
    const type_names = try modules.typeNamesAnalyzed(owned, batch.backing, program, identities, batch.analysis.value.value.state);

    return .{
        .arena = arena,
        .public_modules = public_modules,
        .types = type_source,
        .signatures = if (options.signatures) try @import("genz").zx.modules.functionSignatures(owned, batch.backing, program, identities, batch.analysis.value, units) else null,
        .modules = files,
        .type_names = type_names,
        .native_modules = native_modules,
        .store_initializers = initializers.entries,
    };
}
