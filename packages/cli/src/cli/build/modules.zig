const std = @import("std");
const compiler = @import("compiler");
const State = @import("../build.zig").State;
const Command = @import("command.zig");
const artifacts = @import("../artifacts.zig");
const process = @import("backend_protocol").process;
const source = @import("cli_source");
const workspace = source.workspace_artifact_constants.@"zx.constants";
const Error = @import("../sources/effects.zig").Error;
const NativeModule = @import("cli_abi").layouts.@"zig:rx_execution_host".NativeBackendModule;

pub fn appendGeneratedModule(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const module = &self.bundle.modules[row];

    self.command.module(.{
        .settings = self.settings,
        .name = module.name,
        .path = self.workspace.module_paths[row],
        .imports = module.imports,
        .includes = &.{},
        .canonical = true,
        .abi = null,
        .translated = null,
    }) catch |err| return self.failure.save(err);
}

pub fn nativeBackendModule(handle: *const anyopaque, index: u64) *const NativeModule {
    const self = State.get(handle);
    const module = &self.project.config.native_modules[@intCast(index)];

    self.module = .{ .name = module.name, .includes = module.include_paths, .path = module.path };

    return &self.module;
}

pub fn bindBackendModule(handle: *const anyopaque, index: u64, includes: []const []const u8, abi: ?[]const u8, path: ?[]const u8) void {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const module = &self.project.config.native_modules[row];

    self.native = .{ .header = module.header, .spec = .{
        .settings = self.settings,
        .name = module.name,
        .path = path orelse undefined,
        .imports = module.dependencies,
        .includes = includes,
        .canonical = true,
        .abi = abi,
        .translated = null,
    } };
}

pub fn writeNativeHeader(handle: *const anyopaque) Error![]const u8 {
    const self = State.get(handle);
    const context = self.context;

    const header = source.workspace_native_header.executeValue(context.allocator, &.{
        .directory = self.workspace.directory,
        .name = self.native.spec.name,
        .header = self.native.header.?,
    }) catch |err| return self.failure.save(err);

    artifacts.retain(context.io, context.allocator, header.path, header.source) catch |err| return self.failure.save(err);

    return header.path;
}

pub fn spawnNativeTranslation(handle: *const anyopaque, header: []const u8) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const translation = &self.translation.?;
    var command: Command = .{ .allocator = context.allocator };

    command.translate(.{
        .tool = self.toolchain.executable,
        .library = self.toolchain.library,
        .local = translation.cache.local,
        .global = translation.cache.global,
        .settings = self.settings,
        .includes = self.native.spec.includes,
        .header = header,
    }) catch |err| return self.failure.save(err);

    translation.pending = process.run(context.io, translation.arena.child_allocator, command.arguments.items, &self.environment.?, .translation) catch |err| return self.failure.save(err);

    return translation.pending.?.succeeded;
}

pub fn bindNativeTranslation(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const translation = &self.translation.?;
    const hash = std.fmt.bytesToHex(translation.pending.?.digest.?, .lower);

    self.native.spec.translated = source.backend_cache_path.executeIn(translation.arena.allocator(), &.{
        .root = translation.cache.local,
        .hash = &hash,
        .stem = self.native.spec.name,
    }) catch |err| return self.failure.save(err);
}

pub fn retainNativeTranslation(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const translation = &self.translation.?;

    translation.responses.append(translation.arena.allocator(), translation.pending.?) catch |err| return self.failure.save(err);

    translation.pending = null;
}

pub fn releaseNativeTranslation(handle: *const anyopaque) void {
    const translation = &State.get(handle).translation.?;

    translation.pending.?.deinit();

    translation.pending = null;
}

pub fn writeNativeAdapter(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const allocator = context.allocator;
    const path = source.workspace_native_path.executeIn(allocator, &.{ .directory = self.workspace.directory, .name = self.native.spec.name, .extension = workspace.zig_extension }) catch |err| return self.failure.save(err);
    const adapter = compiler.zig.host.cAdapter(allocator) catch |err| return self.failure.save(err);

    defer allocator.free(adapter);
    artifacts.retain(context.io, allocator, path, adapter) catch |err| return self.failure.save(err);

    self.native.spec.path = path;
}

pub fn appendNativeModule(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.command.module(self.native.spec) catch |err| return self.failure.save(err);
}

pub fn appendAbiView(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const view = &self.abi.views[@intCast(index)];

    appendSupport(self, view.name, view.path, &.{Command.constants.canonical_dependency}) catch |err| return self.failure.save(err);
}

pub fn appendCanonicalAbi(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    appendSupport(self, Command.constants.abi_module, Command.constants.abi_source, &.{}) catch |err| return self.failure.save(err);
}

pub fn appendNapiModule(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    appendSupport(self, Command.constants.napi_module, Command.constants.napi_source, &.{Command.constants.application_module}) catch |err| return self.failure.save(err);
}

fn appendSupport(self: *State, name: []const u8, file: []const u8, imports: []const []const u8) !void {
    const path = try std.fmt.allocPrint(self.context.allocator, "{s}/{s}", .{ self.workspace.directory, file });

    try self.command.module(.{
        .settings = self.settings,
        .name = name,
        .path = path,
        .imports = imports,
        .includes = &.{},
        .canonical = false,
        .abi = null,
        .translated = null,
    });
}
