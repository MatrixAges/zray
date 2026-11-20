const std = @import("std");
const compiler = @import("compiler");
const State = @import("../build.zig").State;
const artifacts = @import("../artifacts.zig");
const node_resources = @import("../node/resources.zig");
const Error = @import("../sources/effects.zig").Error;

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

    self.abi = @import("../abi.zig").create(self.context.allocator, self.bundle, self.project.*) catch |err| return self.failure.save(err);
}

pub fn resolveNativeTarget(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.wasm = @import("../wasm/target.zig").freestanding(self.context.options.target) catch |err| return self.failure.save(err);

    return self.wasm;
}

pub fn generateNodeRunner(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    if (self.wasm or self.bundle.runner != null) return self.failure.save(error.UnsupportedNodeRunner);

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

pub fn retainNodeResources(handle: *const anyopaque) Error!void {
    const builtin = @import("builtin");
    const self = State.get(handle);
    const context = self.context;
    const options = context.options;

    const target = if (options.target) |triple|
        std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| return self.failure.save(err)

    else
        std.Target.Query.fromTarget(&builtin.target);

    const os = target.os_tag orelse builtin.os.tag;
    const arch = target.cpu_arch orelse builtin.cpu.arch;

    if (arch == .wasm32 or arch == .wasm64) return self.failure.save(error.UnsupportedNodeTarget);
    if (os == .windows and options.node_library == null) return self.failure.save(error.NodeImportLibraryRequired);

    if (options.node_library) |path| {
        self.node_library = std.fs.path.resolve(context.allocator, &.{path}) catch |err| return self.failure.save(err);
    }

    const node = std.fs.path.join(context.allocator, &.{ self.workspace.directory, "node" }) catch |err| return self.failure.save(err);
    const sources = &self.node_sources.?;

    artifacts.retainFiles(context.io, context.allocator, node, &sources.files) catch |err| return self.failure.save(err);

    const napi = std.fs.path.join(context.allocator, &.{ self.workspace.directory, "napi" }) catch |err| return self.failure.save(err);

    artifacts.retainFiles(context.io, context.allocator, napi, &sources.napi) catch |err| return self.failure.save(err);
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
