const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("rx_analysis");
const rx = @import("rx");
const entry = @import("../analyze.zig");
const collection = @import("../collection.zig");
const Sources = @import("../../sources.zig");
const Libraries = @import("../../library/inputs.zig");
const effects = @import("../../sources/effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").prepare_rx_project;
const Inferred = analysis.module.Result;
const memory = @import("zx").memory;
const LoadedRange = @import("cli_abi").layouts.@"zig:rx_preparation_host".LoadedRange;

const State = struct {
    allocator: std.mem.Allocator,
    options: *const entry.Options,
    root: []const u8,
    owner: []const u8,
    libraries: Libraries,
    traversal: Sources.Traversal,
    failure: effects.Failure = .{},
    known: Sources.Known = .empty,
    loaded: ?collection.Result = null,
    physical_root: ?[]const u8 = null,
    functions: []const rx.TextSource = &.{},
    paths: [][]const u8 = &.{},
    loaded_view: LoadedRange = undefined,
    inferred: ?Inferred = null,
    evidence_paths: memory.TextColumn = undefined,
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.inferred) |*result| result.deinit();

        self.traversal.deinit();
        self.known.deinit(self.allocator);
        self.allocator.free(self.paths);

        if (self.physical_root) |path| self.allocator.free(path);
        if (self.loaded) |*loaded| loaded.deinit();

        self.libraries.deinit();
    }

    fn finish(self: *State, paths: []const []const u8) !entry.Result {
        const inferred = &self.inferred.?;
        const contract = &inferred.value.contract;
        const evidence = self.loaded.?.data.sources;
        const sources = try self.traversal.sources.addManyAsSlice(self.allocator, evidence.len);

        for (sources, evidence, paths) |*slot, source, path| {
            slot.* = .{ .path = path, .source = source.source };
        }

        const result: entry.Result = .{
            .analysis = .{
                .arena = inferred.arena,
                .value = .{ .ir = contract.program },
                .nominal_types = contract.nominal_types,
                .store_initializers = contract.store_initializers,
                .entry_function = contract.entry_function,
                .public_functions = contract.public_functions,
            },
            .sources = try self.traversal.sources.toOwnedSlice(self.allocator),
            .store_definitions = contract.store_definitions,
        };

        self.inferred = null;

        return result;
    }
    fn validatePath(self: *State, path: []const u8) !void {
        const io = self.options.io;
        const allocator = self.allocator;
        const inputs = self.options.inputs;

        if (inputs) |observed| try observed.add(io, path);

        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);

        defer allocator.free(real);

        const root = self.physical_root.?;
        const relative = try std.fs.path.relative(allocator, root, null, root, real);

        defer allocator.free(relative);

        if (collection.outside(relative)) return error.RxSourceOutsideProject;
        try @import("../../../package/source.zig").validateWithInputs(io, allocator, path, self.options.project.package_scopes, inputs);
    }
};

pub fn run(allocator: std.mem.Allocator, options: *const entry.Options) !?entry.Result {
    const project = options.project;
    const root = try std.fs.path.resolve(allocator, &.{project.root_dir});
    const owner = try std.fs.path.relative(allocator, root, null, root, project.entry);

    if (collection.outside(owner)) return error.RxEntryOutsideProject;

    var state: State = .{
        .allocator = allocator,
        .options = options,
        .root = root,
        .owner = owner,
        .libraries = .{ .allocator = allocator },
        .traversal = undefined,
    };

    state.traversal = .{
        .io = options.io,
        .allocator = allocator,
        .project = project,
        .cache = options.parse_cache,
        .inputs = options.inputs,
        .libraries = &state.libraries,
        .known = &state.known,
        .texts = options.texts,
    };

    const reference = &state;

    const request: std.meta.Child(rule.Input) = .{
        .preparation = @ptrCast(&reference),
        .scoped = project.package_scopes.len != 0,
        .root = root,
        .evidence_paths = @ptrCast(&state.evidence_paths),
    };

    defer state.deinit();

    const paths = rule.executeIn(allocator, &request) catch |err| return state.failure.unwrap(err);

    return try state.finish(paths orelse return null);
}

pub fn loadPreparationDocuments(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const options = self.options;

    self.loaded = collection.load(self.allocator, .{
        .io = options.io,
        .root = self.root,
        .entry = self.owner,
        .writer = options.writer,
        .inputs = options.inputs,
        .project = options.project,
        .parse_cache = options.parse_cache,
        .libraries = &self.libraries,
        .retained_source_allocator = self.allocator,
        .texts = options.texts,
    }) catch |err| return self.failure.save(err);

    return self.loaded != null;
}

pub fn preparePhysicalRoot(handle: *const anyopaque) Error!u64 {
    const self = State.get(handle);

    self.physical_root = std.Io.Dir.cwd().realPathFileAlloc(self.options.io, self.root, self.allocator) catch |err| return self.failure.save(err);

    return self.loaded.?.data.modules.len;
}

pub fn validatePreparedModule(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const module = &self.loaded.?.data.modules[@intCast(index)];
    const path = std.fs.path.resolve(self.allocator, &.{ self.root, module.path }) catch |err| return self.failure.save(err);

    defer self.allocator.free(path);
    self.validatePath(path) catch |err| return self.failure.save(err);
}

pub fn collectPreparationTypes(handle: *const anyopaque) Error!?u64 {
    const self = State.get(handle);
    const options = self.options;
    const loaded = &self.loaded.?.data;

    self.functions = (@import("../type_sources.zig").collect(self.allocator, .{
        .io = options.io,
        .project = options.project,
        .modules = loaded.modules,
        .stores = loaded.stores,
        .functions = loaded.functions,
        .writer = options.writer,
        .inputs = options.inputs,
        .texts = options.texts,
    }) catch |err| return self.failure.save(err)) orelse return null;

    self.paths = self.allocator.alloc([]const u8, self.functions.len) catch |err| return self.failure.save(err);

    return self.paths.len;
}

pub fn registerPreparationRoot(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const function = &self.functions[row];
    const path = std.fs.path.resolve(self.allocator, &.{ self.root, function.path }) catch |err| return self.failure.save(err);

    self.paths[row] = path;

    self.known.put(self.allocator, path, function.source) catch |err| return self.failure.save(err);
}

pub fn loadPreparationRoot(handle: *const anyopaque, index: u64) Error!?*const LoadedRange {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const path = self.paths[row];

    if (self.traversal.hasSeen(path)) return null;

    self.validatePath(path) catch |err| return self.failure.save(err);

    const first = self.traversal.sources.items.len;

    _ = self.traversal.readEntry(path, self.functions[row].source, true) catch |err| return self.failure.save(err);

    self.loaded_view = .{
        .first = first,
        .count = self.traversal.sources.items.len,
    };

    return &self.loaded_view;
}

pub fn validatePreparedSource(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const source = &self.traversal.sources.items[@intCast(index)];

    self.validatePath(source.path) catch |err| return self.failure.save(err);
}

pub fn collectPreparationLibraries(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const options = self.options;

    return @import("../compiled.zig").collect(self.allocator, .{
        .io = options.io,
        .modules = self.loaded.?.data.modules,
        .project = options.project,
        .libraries = &self.libraries,
        .inputs = options.inputs,
        .writer = options.writer,
    }) catch |err| return self.failure.save(err);
}

pub fn inferPreparedProject(handle: *const anyopaque) Error!?u64 {
    const self = State.get(handle);
    const options = self.options;
    const loaded = &self.loaded.?.data;
    var project = options.project;
    project.compiled_libraries = self.libraries.libraries.items;

    self.inferred = analysis.project.infer(self.allocator, .{
        .entry = self.owner,
        .exports = options.exports,
        .modules = loaded.modules,
        .stores = loaded.stores,
        .sources = self.traversal.sources.items,
        .project = project,
        .parse_cache = options.parse_cache,
        .scratch_allocator = std.heap.smp_allocator,
    }) catch |err| return self.failure.save(err);

    const value = &self.inferred.?.value;

    if (value.* != .diagnostic) {
        self.evidence_paths = memory.borrowTextColumn("path", loaded.sources);

        return loaded.sources.len;
    }

    const issue = value.diagnostic;

    options.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

    return null;
}
