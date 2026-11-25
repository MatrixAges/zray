const std = @import("std");
const compiler = @import("compiler");
const builtin = @import("builtin");
const source = @import("cli_source");
const zx = @import("zx");
const State = @import("../build.zig").State;
const artifacts = @import("../artifacts.zig");
const node_resources = @import("../node/resources.zig");
const Error = @import("../sources/effects.zig").Error;
const BackendTarget = @import("cli_abi").layouts.@"zig:rx_execution_host".BackendTarget;
const NodeTarget = @import("cli_abi").native.@"zig:rx_execution_host".NodeTarget;

pub fn validateNativePorts(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const signature = self.bundle.signature orelse return;
    const allocator = self.context.allocator;
    const input = compiler.ir.containsNativeReference(allocator, signature.types, signature.input) catch |err| return self.failure.save(err);

    if (input) return self.failure.save(error.UnsupportedHostReference);

    const output = compiler.ir.containsNativeReference(allocator, signature.types, signature.output) catch |err| return self.failure.save(err);

    if (output) return self.failure.save(error.UnsupportedHostReference);
}

pub fn generateNodeResources(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const signature = self.bundle.signature orelse return self.failure.save(error.MissingNodeSignature);

    self.node_sources = node_resources.create(self.context.allocator, self.bundle.state_module != null, signature.types, signature.input, signature.output) catch |err| return self.failure.save(err);
}

pub fn encodeBackendConfiguration(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    var options = self.context.options;
    options.cache = true;
    options.cache_stats = false;
    options.watch = false;
    options.run = false;
    options.run_args = &.{};
    const node_files: []const node_resources.File = if (self.node_sources) |*sources| &sources.files else &.{};
    const napi_files: []const node_resources.File = if (self.node_sources) |*sources| &sources.napi else &.{};

    self.configuration = std.json.Stringify.valueAlloc(self.context.allocator, .{
        .options = options,
        .project = self.project,
        .node_host_sources = node_files,
        .node_sources = napi_files,
    }, .{}) catch |err| return self.failure.save(err);
}

pub fn prepareBackendAbi(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.abi = @import("../abi.zig").create(self.context.allocator, self.bundle, self.project) catch |err| return self.failure.save(err);

    self.abi_views.init(self.abi.views);
}

pub fn readNativeTarget(handle: *const anyopaque) Error!*const BackendTarget {
    const self = State.get(handle);
    const options = self.context.options;

    const query = if (options.target) |triple|
        std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| return self.failure.save(err)

    else
        std.Target.Query{};

    self.target = .{
        .arch = if (query.cpu_arch) |arch| @tagName(arch) else null,
        .os = if (query.os_tag) |os| @tagName(os) else null,
        .host_arch = @tagName(builtin.cpu.arch),
        .host_os = @tagName(builtin.os.tag),
        .node_library = options.node_library,
    };

    return &self.target;
}

pub fn generateNodeRunner(handle: *const anyopaque, wasm: bool) Error!void {
    const self = State.get(handle);

    if (wasm or self.bundle.runner != null) return self.failure.save(error.UnsupportedNodeRunner);

    self.runner = compiler.zig.host.node.runner(self.context.allocator, self.bundle.state_module != null) catch |err| return self.failure.save(err);
}

pub fn generateWasmRunner(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    if (self.bundle.runner != null) return self.failure.save(error.UnsupportedWasmRunner);

    const signature = self.bundle.signature orelse return self.failure.save(error.MissingApplicationSignature);

    self.runner = compiler.zig.host.wasm(self.context.allocator, self.bundle.state_module != null, .{ .types = signature.types, .id = signature.output }) catch |err| return self.failure.save(err);
}

pub fn writeBackendWorkspace(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.workspace = artifacts.prepare(context.io, context.allocator, self.bundle, self.runner, self.configuration, self.abi, context.options.result == .json) catch |err| return self.failure.save(err);
}

pub fn retainNodeResources(handle: *const anyopaque, target: NodeTarget) Error!void {
    const self = State.get(handle);
    const context = self.context;

    switch (target) {
        .Ready => {},
        .UnsupportedNodeTarget => return self.failure.save(error.UnsupportedNodeTarget),
        .NodeImportLibraryRequired => return self.failure.save(error.NodeImportLibraryRequired),
    }

    if (context.options.node_library) |path| {
        self.node_library = std.fs.path.resolve(context.allocator, &.{path}) catch |err| return self.failure.save(err);
    }

    const native = &self.node_sources.?;
    const node: []const node_resources.File = &native.files;
    const napi: []const node_resources.File = &native.napi;
    const node_paths = zx.memory.borrowTextColumn("path", node);
    const node_sources = zx.memory.borrowTextColumn("source", node);
    const napi_paths = zx.memory.borrowTextColumn("path", napi);
    const napi_sources = zx.memory.borrowTextColumn("source", napi);
    var disk: @import("artifact_io").Context = .{ .io = context.io };

    source.workspace_host_resources.executeIn(context.allocator, &.{
        .fs = @ptrCast(&disk),
        .directory = self.workspace.directory,
        .separator = &.{std.fs.path.sep},
        .node = &.{ .count = node.len, .paths = @ptrCast(&node_paths), .sources = @ptrCast(&node_sources) },
        .napi = &.{ .count = napi.len, .paths = @ptrCast(&napi_paths), .sources = @ptrCast(&napi_sources) },
    }) catch |err| return self.failure.save(disk.unwrap(err));
}

pub fn releaseBackendSources(handle: *const anyopaque) void {
    State.get(handle).releaseSources();
}

pub fn prepareStagedParents(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const io = self.context.io;
    const staged = self.staged.?;

    ensureParent(io, staged.binary) catch |err| return self.failure.save(err);

    if (staged.assembly) |path| ensureParent(io, path) catch |err| return self.failure.save(err);
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    var directory = try std.Io.Dir.cwd().createDirPathOpen(io, parent, .{});

    directory.close(io);
}
