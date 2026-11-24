const std = @import("std");
const rx = @import("rx");
const compiler = @import("compiler");
const project = @import("../project.zig");
const graph = @import("rx_analysis").project.source_graph;
const functions_check = @import("function.zig");
const collection = @import("collection.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const CheckRows = @import("cli_abi").layouts.@"zig:rx_checking_host".CheckRows;

const State = struct {
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
    calls: []std.ArrayList(functions_check.Selection) = &.{},
    rows: CheckRows = undefined,
    graph_entry: []const u8 = undefined,
    sources: []compiler.project.Source = &.{},
    roots: [][]const u8 = &.{},
    graph_result: ?graph.Result = null,
    call_index: functions_check.CallIndex = undefined,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn closeGraph(self: *State) void {
        if (self.graph_result) |*result| result.deinit();

        self.graph_result = null;

        self.allocator.free(self.roots);
        self.allocator.free(self.sources);

        self.roots = &.{};
        self.sources = &.{};
    }

    fn closeFunctions(self: *State) void {
        if (self.scratch) |*scratch| scratch.deinit();

        self.scratch = null;
    }

    fn deinit(self: *State) void {
        self.closeFunctions();
        self.closeGraph();
        for (self.calls) |*rows| rows.deinit(self.allocator);

        self.allocator.free(self.calls);
        if (self.loaded) |*loaded| loaded.deinit();
    }
};

pub fn check(io: std.Io, allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, backing: std.mem.Allocator, entry: []const u8, config_path: ?[]const u8, writer: *std.Io.Writer) !bool {
    var state: State = .{
        .io = io,
        .allocator = allocator,
        .result_allocator = result_allocator,
        .backing = backing,
        .entry = entry,
        .config_path = config_path,
        .writer = writer,
    };

    const reference = &state;

    defer state.deinit();

    return @import("cli_source").check_rx_project.executeIn(allocator, @ptrCast(&reference)) catch |err| state.failure.unwrap(err);
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

pub fn collectCheckTypes(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const loaded = &self.loaded.?.data;

    self.functions = (@import("type_sources.zig").collect(self.allocator, .{
        .io = self.io,
        .project = self.project,
        .modules = loaded.modules,
        .stores = loaded.stores,
        .functions = loaded.functions,
        .writer = self.writer,
    }) catch |err| return self.failure.save(err)) orelse return false;

    return true;
}

pub fn reserveCheckCalls(handle: *const anyopaque) Error!*const CheckRows {
    const self = State.get(handle);

    self.calls = self.allocator.alloc(std.ArrayList(functions_check.Selection), self.functions.len) catch |err| return self.failure.save(err);

    @memset(self.calls, .empty);

    const documents = &self.loaded.?.data;

    self.rows = .{ .source_count = self.functions.len, .module_count = documents.modules.len, .gateway = documents.gateway != null };

    return &self.rows;
}

pub fn reserveCheckGraph(handle: *const anyopaque, gateway: bool) Error!void {
    const self = State.get(handle);
    const modules = self.loaded.?.data.modules;
    const allocator = self.allocator;

    self.graph_entry = if (gateway) modules[0].path else self.owner;
    self.sources = allocator.alloc(compiler.project.Source, self.functions.len) catch |err| return self.failure.save(err);
    self.roots = allocator.alloc([]const u8, modules.len) catch |err| return self.failure.save(err);
}

pub fn registerCheckSource(handle: *const anyopaque, index: u64) void {
    const self = State.get(handle);
    const function = self.functions[@intCast(index)];

    self.sources[@intCast(index)] = .{ .path = function.path, .source = function.source };
}

pub fn registerCheckRoot(handle: *const anyopaque, index: u64) void {
    const self = State.get(handle);
    const row: usize = @intCast(index);

    self.roots[row] = self.loaded.?.data.modules[row].path;
}

pub fn buildCheckGraph(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const loaded = &self.loaded.?.data;

    self.graph_result = graph.build(self.allocator, .{
        .entry = self.graph_entry,
        .additional_roots = self.roots,
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

    self.call_index = .{ .graph = &result.graph, .modules = loaded.modules, .calls = self.calls };

    return true;
}

pub fn selectCheckCallModule(handle: *const anyopaque, index: u64) u64 {
    return State.get(handle).call_index.selectModule(@intCast(index));
}

pub fn isCheckCallEdge(handle: *const anyopaque, index: u64) bool {
    return State.get(handle).call_index.isCall(@intCast(index));
}

pub fn takeCheckCallReference(handle: *const anyopaque) bool {
    return State.get(handle).call_index.takeReference();
}

pub fn recordCheckFunctionCall(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);

    self.call_index.record(self.allocator, @intCast(index)) catch |err| return self.failure.save(err);
}

pub fn closeCheckGraph(handle: *const anyopaque) void {
    State.get(handle).closeGraph();
}

pub fn checkStoreTypes(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    return @import("store_types.zig").validate(self.io, self.allocator, self.loaded.?.data, self.functions, self.project, self.writer) catch |err| return self.failure.save(err);
}

pub fn beginCheckFunctions(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.scratch = std.heap.ArenaAllocator.init(self.backing);
}

pub fn checkFunction(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const allocator = self.scratch.?.allocator();
    const row: usize = @intCast(index);
    const function = self.functions[row];
    const path = std.fs.path.resolve(allocator, &.{ self.root, function.path }) catch |err| return self.failure.save(err);
    const valid = functions_check.validate(self.io, allocator, path, function.source, self.config_path, self.loaded.?.data.modules, self.calls[row].items, self.writer) catch |err| return self.failure.save(err);

    if (valid) _ = self.scratch.?.reset(.retain_capacity);

    return valid;
}

pub fn closeCheckFunctions(handle: *const anyopaque) void {
    State.get(handle).closeFunctions();
}

pub fn checkCompiledModules(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
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
