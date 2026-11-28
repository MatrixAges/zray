const std = @import("std");
const rx = @import("rx");
const compiler = @import("compiler");
const project = @import("../project.zig");
const graph = @import("rx_analysis").project.source_graph;
const functions_check = @import("function.zig");
const collection = @import("collection.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const checking_abi = @import("cli_abi").layouts.@"zig:rx_checking_host";
const checking_native = @import("cli_abi").native.@"zig:rx_checking_host";
const CheckRows = checking_abi.CheckRows;
const SelectedCall = checking_native.SelectedCall;
const CallEdgeLayout = checking_abi.CallEdge;
const CallEdge = checking_native.CallEdge;
const CallReferenceLayout = checking_abi.CallReference;
const CallReference = checking_native.CallReference;
const ModuleCalls = checking_abi.ModuleCalls;

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    scratch: ?std.heap.ArenaAllocator = null,
    backing: std.mem.Allocator,
    entry: []const u8,
    config_path: ?[]const u8,
    writer: *std.Io.Writer,
    project: compiler.project.Options = undefined,
    root: []const u8 = undefined,
    owner: []const u8 = undefined,
    loaded: ?collection.Result = null,
    functions: []const rx.TextSource = &.{},
    rows: CheckRows = undefined,
    sources: []compiler.project.Source = &.{},
    roots: [][]const u8 = &.{},
    graph_result: ?graph.Result = null,
    call_edges: []CallEdgeLayout = &.{},
    call_edge_ptrs: []CallEdge = &.{},
    call_references: []CallReferenceLayout = &.{},
    call_reference_ptrs: []CallReference = &.{},
    module_calls: ModuleCalls = undefined,
    function: ?functions_check.Function = null,
    failure: effects.Failure = .{},
    pub fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn freeCallScratch(self: *State) void {
        self.allocator.free(self.call_reference_ptrs);
        self.allocator.free(self.call_references);
        self.allocator.free(self.call_edge_ptrs);
        self.allocator.free(self.call_edges);

        self.call_reference_ptrs = &.{};
        self.call_references = &.{};
        self.call_edge_ptrs = &.{};
        self.call_edges = &.{};
    }

    fn closeGraph(self: *State) void {
        if (self.graph_result) |*result| result.deinit();

        self.graph_result = null;

        self.freeCallScratch();
        self.allocator.free(self.sources);

        self.sources = &.{};
    }

    fn closeFunctions(self: *State) void {
        if (self.function) |*function| function.deinit();
        if (self.scratch) |*scratch| scratch.deinit();

        self.function = null;
        self.scratch = null;
    }

    fn deinit(self: *State) void {
        self.closeFunctions();
        self.closeGraph();
        self.allocator.free(self.roots);
        if (self.loaded) |*loaded| loaded.deinit();
    }
};

pub fn check(io: std.Io, allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, backing: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8, writer: *std.Io.Writer) !bool {
    var state: State = .{
        .io = io,
        .allocator = allocator,
        .result_allocator = result_allocator,
        .backing = backing,
        .scratch = std.heap.ArenaAllocator.init(backing),
        .entry = entry,
        .config_path = config_path,
        .writer = writer,
    };

    const reference = &state;

    defer state.deinit();

    const outcome = @import("cli_source").check_rx_project.executeIn(allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    if (outcome.diagnostic) |message| try writer.writeAll(message);

    return outcome.valid;
}

pub fn loadCheckProject(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const allocator = self.allocator;
    const loaded = project.load(self.io, allocator, self.entry, self.config_path) catch |err| return self.failure.save(err);

    if (loaded.diagnostic) |message| {
        self.writer.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return false;
    }

    self.project = loaded.project;
    self.root = std.fs.path.resolve(allocator, &.{loaded.project.root_dir}) catch |err| return self.failure.save(err);
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", allocator) catch |err| return self.failure.save(err);
    const absolute = std.fs.path.resolve(allocator, &.{ cwd, self.entry }) catch |err| return self.failure.save(err);

    self.owner = std.fs.path.relative(allocator, self.root, null, self.root, absolute) catch |err| return self.failure.save(err);

    return true;
}

pub fn collectCheckDocuments(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.loaded = collection.load(self.allocator, .{
        .io = self.io,
        .root = self.root,
        .entry = self.owner,
        .writer = self.writer,
        .project = self.project,
    }) catch |err| return self.failure.save(err);

    return self.loaded != null;
}

pub fn collectCheckTypes(handle: *const anyopaque) Error!?*const CheckRows {
    const self = State.get(handle);
    const loaded = &self.loaded.?.data;

    self.functions = (@import("type_sources.zig").collect(self.allocator, .{
        .io = self.io,
        .project = self.project,
        .modules = loaded.modules,
        .stores = loaded.stores,
        .functions = loaded.functions,
        .writer = self.writer,
    }) catch |err| return self.failure.save(err)) orelse return null;

    self.roots = self.allocator.alloc([]const u8, loaded.modules.len) catch |err| return self.failure.save(err);

    for (loaded.modules, self.roots) |module, *path| path.* = module.path;

    self.rows = .{
        .source_count = self.functions.len,
        .gateway = loaded.gateway != null,
        .owner = self.owner,
        .roots = self.roots,
    };

    return &self.rows;
}

pub fn buildCheckGraph(handle: *const anyopaque, entry: []const u8, roots: []const []const u8) Error!bool {
    const self = State.get(handle);
    const loaded = &self.loaded.?.data;

    self.sources = self.allocator.alloc(compiler.project.Source, self.functions.len) catch |err| return self.failure.save(err);

    for (self.functions, self.sources) |function, *source| {
        source.* = .{ .path = function.path, .source = function.source };
    }

    self.graph_result = graph.build(self.allocator, .{
        .entry = entry,
        .additional_roots = roots,
        .sources = self.sources,
        .modules = loaded.modules,
        .stores = loaded.stores,
        .project = self.project,
        .scratch_allocator = self.backing,
    }) catch |err| return self.failure.save(err);

    const result = &self.graph_result.?.value;

    if (result.* == .diagnostic) {
        const issue = result.diagnostic;

        self.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

pub fn readCheckCallModule(handle: *const anyopaque, index: u64) Error!*const ModuleCalls {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const graph_value = &self.graph_result.?.value.graph;
    const raw_edges = graph_value.modules.items(.dependencies)[graph_value.sources.zx_count + row];
    const raw_references = self.loaded.?.data.modules[row].indexedReferences() orelse unreachable;

    self.freeCallScratch();

    self.call_edges = self.allocator.alloc(CallEdgeLayout, raw_edges.len) catch |err| return self.failure.save(err);
    self.call_edge_ptrs = self.allocator.alloc(CallEdge, raw_edges.len) catch |err| return self.failure.save(err);
    self.call_references = self.allocator.alloc(CallReferenceLayout, raw_references.len) catch |err| return self.failure.save(err);
    self.call_reference_ptrs = self.allocator.alloc(CallReference, raw_references.len) catch |err| return self.failure.save(err);

    for (raw_edges, self.call_edges, self.call_edge_ptrs) |edge, *slot, *ptr| {
        const target_source: u64 = if (edge.reference == .call) switch (edge.target) {
            .source => |source| source,
            else => 0,
        } else 0;

        slot.* = .{
            .is_call = edge.reference == .call,
            .named = edge.named,
            .target_source = target_source,
        };

        ptr.* = slot;
    }

    for (raw_references, self.call_references, self.call_reference_ptrs) |reference, *slot, *ptr| {
        const is_call = reference.role == .Call;
        const is_function = is_call and reference.target == .Function;

        slot.* = if (is_function) .{
            .is_call = true,
            .is_function = true,
            .value = reference.attribute.?.value,
            .line = reference.attribute.?.value_location.line,
            .column = reference.attribute.?.value_location.column,
        } else .{
            .is_call = is_call,
            .is_function = false,
            .value = "",
            .line = 0,
            .column = 0,
        };

        ptr.* = slot;
    }

    self.module_calls = .{
        .edges = self.call_edge_ptrs,
        .references = self.call_reference_ptrs,
    };

    return &self.module_calls;
}

pub fn checkStoreTypes(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.closeGraph();

    return @import("store_types.zig").validate(self.io, self.allocator, self.loaded.?.data, self.functions, self.project, self.writer) catch |err| return self.failure.save(err);
}

pub fn prepareCheckFunction(handle: *const anyopaque, index: u64, calls: []const SelectedCall) Error![]const u8 {
    const self = State.get(handle);
    const scratch = &self.scratch.?;

    if (self.function) |*previous| {
        previous.deinit();

        self.function = null;
        _ = scratch.reset(.retain_capacity);
    }

    const allocator = scratch.allocator();
    const function = self.functions[@intCast(index)];
    const path = std.fs.path.resolve(allocator, &.{ self.root, function.path }) catch |err| return self.failure.save(err);
    const selections = allocator.alloc(functions_check.Selection, calls.len) catch |err| return self.failure.save(err);

    for (calls, selections) |call, *selection| selection.* = call.*;

    self.function = functions_check.Function.init(allocator, path, function.source, selections);

    return path;
}

pub fn checkCompiledModules(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.closeFunctions();

    var libraries = @import("../library/inputs.zig"){ .allocator = self.allocator };

    defer libraries.deinit();

    return @import("compiled.zig").collect(self.allocator, .{
        .io = self.io,
        .modules = self.loaded.?.data.modules,
        .project = self.project,
        .libraries = &libraries,
        .inputs = null,
        .writer = self.writer,
    }) catch |err| return self.failure.save(err);
}

pub fn checkModulePaths(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const modules = self.loaded.?.data.modules;
    var result = rx.validateModulePaths(self.result_allocator, modules) catch |err| return self.failure.save(err);

    defer result.deinit();

    if (result.value != .diagnostic) return true;

    const diagnostic = result.value.diagnostic;

    return @import("check.zig").report(self.writer, modules[diagnostic.source_index].path, diagnostic.issue) catch |err| self.failure.save(err);
}
