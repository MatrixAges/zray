const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("../../../project.zig");
const target = @import("../../../call/target.zig");
const preparation = @import("../../prepare.zig");
const registry = @import("../../../store/registry.zig");
const source_graph = project.source_graph;
const Frame = @import("../../history.zig").Frame;
const Inputs = @import("../../call_inputs.zig");
const entry_source = @import("../../entry.zig");
const workflow = @import("../errors.zig");
const Error = zx.Error;
const generated = @import("rx_options").generated_graph;

pub fn run(allocator: std.mem.Allocator, backing: std.mem.Allocator, options: *const project.Options, cache: *frontend.project.ParseCache, inputs: *Inputs, frame: *Frame, issue: *?target.Diagnostic, check_signatures: bool) Error!void {
    var state: State = .{
        .allocator = allocator,
        .backing = backing,
        .options = options,
        .cache = cache,
        .inputs = inputs,
        .frame = frame,
        .issue = issue,
        .project_options = options.project,
    };

    state.project_options.source_index = null;

    defer state.prefetched.deinit(backing);
    defer state.paths.deinit(backing);
    defer if (state.entries.len != 0) backing.free(state.entries);

    if (comptime generated) {
        const entry = @import("generated_rx_execute_derivation");
        const input: std.meta.Child(entry.Input) = .{ .state = @ptrCast(&state), .retained = check_signatures };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return entry.executeIn(empty.allocator(), &input) catch |err| workflow.errorSet(err);
    }

    try state.modules();
    try state.graph();
    try state.orderSignatures();
    if (!check_signatures or !state.restoreSignatures()) try state.analyzeSignatures();
    try state.index();
    try state.stores();
    try state.prepare();
    try @import("../solve/host.zig").run(&state);
    try state.completeShortcuts();

    state.publish();
}

pub const State = struct {
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    options: *const project.Options,
    cache: *frontend.project.ParseCache,
    inputs: *Inputs,
    frame: *Frame,
    issue: *?target.Diagnostic,
    project_options: frontend.project.Options,
    paths: frontend.project.source_index.Map = .empty,
    prefetched: frontend.project.ParseCache.Prefetched = .{},
    sources: []const rx.ModuleSource = &.{},
    entry: []const u8 = "",
    entry_index: ?usize = null,
    dependencies: ?source_graph.Graph = null,
    entries: []const u64 = &.{},
    signatures_data: ?frontend.project.signature_project.Data = null,
    indexed: ?source_graph.Signatures = null,
    registered: ?registry.Data = null,
    prepared: ?preparation.Loaded = null,
    fn modules(self: *State) Error!void {
        const options = self.options;
        const allocator = self.allocator;
        const items = try allocator.dupe(rx.ModuleSource, options.modules);
        var owner_buffer: [512]u8 = undefined;
        var scope_paths = std.heap.BufferFirstAllocator.init(&owner_buffer, self.backing);
        const temporary = scope_paths.allocator();

        for (items) |*source| {
            const owner = try std.fs.path.resolve(temporary, &.{ self.project_options.root_dir, source.path });

            defer temporary.free(owner);

            source.packages = rx.module_reference.dependencies(self.project_options, owner);
        }

        const checked = try rx.validateModulePaths(allocator, items);

        if (checked.value == .diagnostic) {
            const issue = checked.value.diagnostic;

            return self.fail(.{ .path = options.modules[issue.source_index].path, .location = issue.issue.location, .code = @tagName(issue.issue.code), .message = issue.issue.message });
        }

        const root: rx.ast.Location = .{ .offset = 0, .line = 1, .column = 1 };
        const is_zx = entry_source.isZX(options.entry);

        const entry = if (is_zx)
            try std.fs.path.resolve(allocator, &.{ self.project_options.root_dir, options.entry })
        else
            rx.normalizeModulePath(allocator, options.entry) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                return self.fail(.{ .path = options.entry, .location = root, .code = "module", .message = "entry must name a registered source module inside the project root" });
            };

        for (items, checked.value.data) |*item, path| item.path = path;

        self.entry = entry;

        self.entry_index = if (is_zx) null else entry_source.lookup(entry, checked.value.data) orelse return self.fail(.{
            .path = entry,
            .location = root,
            .code = "module",
            .message = "RX entry is not registered in the module collection",
        });

        self.sources = items;
    }
    fn graph(self: *State) Error!void {
        const options = self.options;

        const result = try source_graph.buildWithRoots(self.allocator, .{
            .entry = if (self.entry_index == null) options.entry else self.entry,
            .include_rx_modules = true,
            .sources = options.sources,
            .modules = self.sources,
            .stores = options.stores,
            .project = self.project_options,
            .parse_cache = self.cache,
            .prefetched = &self.prefetched,
            .scratch_allocator = self.backing,
            .registered_paths = &self.paths,
            .retain_source_dependencies = options.history != null,
        }, options.exports);

        if (result.value == .diagnostic) return self.fail(result.value.diagnostic);

        self.dependencies = result.value.graph;
    }

    fn restoreSignatures(self: *State) bool {
        const record = self.options.history.?;
        const earlier = record.signatures(self.options.sources, &self.dependencies.?, self.entries) orelse return false;

        record.signatures_reused = true;
        self.signatures_data = earlier;

        return true;
    }
    fn analyzeSignatures(self: *State) Error!void {
        const result = try frontend.project.analyzePrefetchedSignatures(self.allocator, self.prefetched, self.entries, self.project_options, &self.paths);

        if (result.value == .diagnostic) {
            const issue = result.value.diagnostic;
            const source = if (issue.source_index) |row| self.options.sources[row] else null;
            const location: zx.source.Location = if (source) |value| zx.source.locate(value.source, issue.span.start) else .{ .line = 1, .column = 1 };

            return self.fail(.{
                .path = if (source) |value| value.path else self.entry,
                .location = .{ .offset = issue.span.start, .line = location.line, .column = location.column },
                .code = @tagName(issue.code),
                .message = issue.message,
            });
        }

        self.signatures_data = result.value.data;
    }

    fn orderSignatures(self: *State) std.mem.Allocator.Error!void {
        self.entries = try source_graph.orderedRows(self.backing, &self.dependencies.?, .zx);
    }

    fn index(self: *State) Error!void {
        self.backing.free(self.entries);

        self.entries = &.{};

        self.prefetched.deinit(self.backing);

        const values = &self.signatures_data.?;

        self.project_options.context.types = values.types;
        self.project_options.context.nominal_types = values.nominal_types;
        self.project_options.context.native_modules = values.native_modules;
        self.indexed = try source_graph.Signatures.init(self.allocator, self.dependencies.?, values.modules, &self.paths);

        self.paths.deinit(self.backing);

        self.paths = .empty;
    }

    fn stores(self: *State) Error!void {
        const dependencies = &self.dependencies.?;
        const edges = dependencies.modules.items(.dependencies)[dependencies.sources.rx_end..];
        const result = try registry.loadSignaturesIn(self.allocator, self.backing, self.options.stores, self.project_options.context, edges, self.indexed.?);

        if (result == .diagnostic) {
            self.issue.* = result.diagnostic;

            return error.InvalidSource;
        }

        self.registered = result.data;
        self.project_options.context = result.data.context;
    }

    fn prepare(self: *State) Error!void {
        const dependencies = &self.dependencies.?;
        const edges = dependencies.modules.items(.dependencies)[dependencies.sources.zx_count..dependencies.sources.rx_end];
        const result = try preparation.loadSignatures(self.allocator, self.backing, self.sources, edges, self.project_options, self.registered.?.definitions, self.indexed.?, self.inputs);

        if (result == .diagnostic) {
            self.issue.* = result.diagnostic;

            return error.InvalidSource;
        }

        self.prepared = result.loaded;
    }

    fn publish(self: *State) void {
        const dependencies = &self.dependencies.?;
        self.frame.stores = self.options.stores;
        self.frame.modules = self.sources;
        self.frame.dependencies = dependencies.*;
        self.frame.export_roots = dependencies.additional_roots[self.sources.len..];
        self.frame.definitions = self.registered.?.definitions;
        self.frame.loaded = self.prepared.?;
        self.frame.signatures = self.signatures_data.?;
        self.frame.signature_indices = self.indexed.?.indices;
    }

    fn completeShortcuts(self: *State) Error!void {
        return preparation.completeShortcuts(self.allocator, self.prepared.?.modules, self.frame.resolved);
    }

    pub fn fail(self: *State, diagnostic: target.Diagnostic) Error {
        const value = try project.failure(self.allocator, diagnostic);

        self.issue.* = value.diagnostic;

        return error.InvalidSource;
    }
};

fn borrow(handle: *const anyopaque) *State {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn prepareDerivedModules(handle: *const anyopaque) Error!void {
    return borrow(handle).modules();
}

pub fn collectDerivedGraph(handle: *const anyopaque) Error!void {
    return borrow(handle).graph();
}

pub fn orderDerivedSignatures(handle: *const anyopaque) std.mem.Allocator.Error!void {
    return borrow(handle).orderSignatures();
}

pub fn restoreDerivedSignatures(handle: *const anyopaque) bool {
    return borrow(handle).restoreSignatures();
}

pub fn analyzeDerivedSignatures(handle: *const anyopaque) Error!void {
    return borrow(handle).analyzeSignatures();
}

pub fn indexDerivedSignatures(handle: *const anyopaque) Error!void {
    return borrow(handle).index();
}

pub fn loadDerivedStores(handle: *const anyopaque) Error!void {
    return borrow(handle).stores();
}

pub fn prepareDerivedFlow(handle: *const anyopaque) Error!void {
    return borrow(handle).prepare();
}

pub fn solveDerivedFlow(handle: *const anyopaque) Error!void {
    return @import("../solve/host.zig").run(borrow(handle));
}

pub fn completeDerivedShortcuts(handle: *const anyopaque) Error!void {
    return borrow(handle).completeShortcuts();
}

pub fn publishDerivedFrame(handle: *const anyopaque) void {
    borrow(handle).publish();
}
