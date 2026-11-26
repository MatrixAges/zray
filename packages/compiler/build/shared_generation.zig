const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("rx_analysis");
const Entry = @import("entries.zig").Entry;
const Resident = @import("resident/state.zig");
const publication = compiler.input_generation;

pub const Target = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    resident: *Resident,
    output: ?[]const u8,
    cache_path: []const u8,
    partitions: u32,
};

const Inputs = struct {
    modules: []const @import("rx").ModuleSource,
    sources: []const compiler.project.Source,
    interfaces: []const compiler.project.NativeInterface,
    internal_modules: []const compiler.project.NativeInterface,
    packages: []const compiler.project.Package,
    /// Identifies every input besides the ZX sources.
    frame: [32]u8,
    /// The frame without the RX sources' texts, and their digests by path.
    shape: [32]u8,
    rx_digests: []const analysis.project.ModuleDigest,
    fingerprint: [32]u8,
};

const Counts = struct {
    entries: usize,
    analyzed: usize,
    reused: usize,
    bodies_only: bool,
};

const PartitionedModules = struct {
    modules: []const @import("rx").ModuleSource,
    stores: []const @import("rx").ModuleSource,
};

fn partitionModules(allocator: std.mem.Allocator, all: []const @import("rx").ModuleSource) !PartitionedModules {
    var store_count: usize = 0;

    for (all) |item| {
        if (std.mem.endsWith(u8, item.path, ".store.rx")) store_count += 1;
    }

    if (store_count == 0) return .{ .modules = all, .stores = &.{} };

    const regular = try allocator.alloc(@import("rx").ModuleSource, all.len - store_count);
    const stores = try allocator.alloc(@import("rx").ModuleSource, store_count);
    var regular_index: usize = 0;
    var store_index: usize = 0;

    for (all) |item| {
        if (std.mem.endsWith(u8, item.path, ".store.rx")) {
            stores[store_index] = item;
            store_index += 1;
        } else {
            regular[regular_index] = item;
            regular_index += 1;
        }
    }

    return .{ .modules = regular, .stores = stores };
}

/// Generates the tree for `entries` into `output`, unless it is null, and returns its summary line. Parsed modules,
/// cached sources and the previous analysis come from `resident`, which keeps them for later requests.
pub fn run(target: Target, owned: std.mem.Allocator, entries: []const Entry, inputs: Inputs) ![]const u8 {
    const allocator = target.allocator;
    const resident = target.resident;
    const started = std.Io.Timestamp.now(target.io, .awake);
    const roots = try allocator.alloc([]const u8, entries.len);
    const exports = try allocator.alloc(analysis.project.Export, entries.len);

    publication.entries(entries, roots, exports);

    const project = compiler.project.Options{
        .entry = "",
        .native_interfaces = inputs.interfaces,
        .internal_modules = inputs.internal_modules,
        .packages = inputs.packages,
    };

    const parse_cache = &resident.parse_cache;
    const partitioned = try partitionModules(owned, inputs.modules);
    const history = resident.startAnalysis(inputs.frame, inputs.shape, inputs.rx_digests, inputs.sources);

    // When only function bodies changed, the earlier analysis already found the reachable modules.
    history.bodies_only = try history.bodiesOnly(inputs.sources, parse_cache);

    const selected = if (history.bodies_only) history.previous.?.modules else try @import("source_inputs.zig").reachable(owned, resident.gpa, partitioned.modules, partitioned.stores, inputs.sources, roots, project, parse_cache);
    // Retired analysis epochs can release their pages without keeping large blocks in malloc.
    const analysis_allocator = if (resident.request != null) std.heap.page_allocator else resident.gpa;

    var analyzed = try analysis.project.infer(analysis_allocator, .{
        .entry = roots[0],
        .exports = exports,
        .modules = selected,
        .stores = partitioned.stores,
        .sources = inputs.sources,
        .project = project,
        .scratch_allocator = resident.gpa,
        .parse_cache = parse_cache,
        .history = history,
    });

    var kept = false;

    defer if (!kept) analyzed.deinit();

    if (analyzed.value == .diagnostic) {
        const issue = analyzed.value.diagnostic;

        std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message });

        return error.InvalidParserSource;
    }

    const contract = analyzed.value.contract;

    const library = compiler.library.Result{
        .arena = analyzed.arena,
        .program = .{
            .file_name = "bootstrap",
            .types = contract.types,
            .input_type = @fromBackingInt(@intCast(@backingInt(compiler.ir.Scalar.void))),
            .output_type = @fromBackingInt(@intCast(@backingInt(compiler.ir.Scalar.void))),
            .symbols = .{},
            .expressions = .{},
            .body = .{},
            .functions = contract.program.functions,
            .native_modules = contract.native_modules,
            .type_only = true,
        },
        .exports = contract.exports,
        .nominal_types = contract.nominal_types,
        .store_initializers = contract.store_initializers,
    };

    const summary = try emit(target, &library, .{
        .entries = entries.len,
        .analyzed = history.analyzed,
        .reused = history.reused,
        .bodies_only = history.bodies_only,
    }, started);

    kept = true;

    try resident.keepAnalysis(library, inputs.fingerprint, history.reused + history.analyzed);

    return summary;
}

pub fn restore(target: Target, analysis_snapshot: Resident.Restored, entry_count: usize) ![]const u8 {
    const summary = try emit(target, analysis_snapshot.library, .{
        .entries = entry_count,
        .analyzed = 0,
        .reused = analysis_snapshot.module_count,
        .bodies_only = false,
    }, std.Io.Timestamp.now(target.io, .awake));

    target.resident.restoreAnalysis(analysis_snapshot.parent_count);

    return summary;
}

fn emit(target: Target, library: *const compiler.library.Result, counts: Counts, started: std.Io.Timestamp) ![]const u8 {
    const io = target.io;
    const resident = target.resident;
    const inferred = std.Io.Timestamp.now(io, .awake);
    const cache = try resident.generationCache(io, target.cache_path);
    const generated = cache.generated;
    const reused = cache.reused;
    const bundle = try compiler.zig.emitLibraryFilesCachedConcurrentWith(resident.gpa, resident.emissionAllocator(), library, cache, .{ .signatures = target.partitions != 0 and !compiler.zig.partition.groups.available });

    defer resident.discard(bundle.arena);

    const emitted = std.Io.Timestamp.now(io, .awake);

    if (target.output) |path| try compiler.zig.file_ledger.tree.write(io, target.allocator, resident.gpa, path, bundle, target.partitions);

    const written = std.Io.Timestamp.now(io, .awake);

    // One-shot requests flush the cache after releasing the emission arena.
    if (resident.request != null) cache.startWriting();

    return publication.report(target.allocator, .{
        .entries = counts.entries,
        .analyzed = counts.analyzed,
        .reused = counts.reused,
        .bodies_only = counts.bodies_only,
        .files = bundle.modules.len,
        .generated = cache.generated - generated,
        .cached = cache.reused - reused,
    }, .{
        .infer = @intCast(started.durationTo(inferred).toMilliseconds()),
        .emit = @intCast(inferred.durationTo(emitted).toMilliseconds()),
        .write = @intCast(emitted.durationTo(written).toMilliseconds()),
    });
}
