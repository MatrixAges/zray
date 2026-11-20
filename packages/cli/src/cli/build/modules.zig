const std = @import("std");
const compiler = @import("compiler");
const State = @import("../build.zig").State;
const project = @import("../project.zig");
const Command = @import("command.zig");
const artifacts = @import("../artifacts.zig");
const Error = @import("../sources/effects.zig").Error;

pub fn generatedModuleCount(handle: *const anyopaque) u64 {
    return State.get(handle).bundle.modules.len;
}

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

pub fn prepareNativeModule(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const allocator = self.context.allocator;
    const row: usize = @intCast(index);
    const module = &self.project.config.native_modules[row];
    const abi_index = project.nativeIndex("module", self.abi.views, module.name, false);
    const scope = project.nativeScope(self.project.*, module.*);
    const includes = @import("arguments.zig").resolvePaths(allocator, scope.root, scope.paths) catch |err| return self.failure.save(err);

    self.native = .{ .row = row, .spec = .{
        .settings = self.settings,
        .name = module.name,
        .path = undefined,
        .imports = module.dependencies,
        .includes = includes,
        .canonical = true,
        .abi = if (abi_index) |selected| self.abi.views[selected].name else null,
        .translated = null,
    } };

    return module.path != null;
}

pub fn resolveNativeModulePath(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const path = self.project.config.native_modules[self.native.row].path.?;

    self.native.spec.path = std.fs.path.resolve(self.context.allocator, &.{ self.project.project.root_dir, path }) catch |err| return self.failure.save(err);
}

pub fn writeNativeHeader(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const allocator = context.allocator;
    const module = &self.project.config.native_modules[self.native.row];
    const directory = self.workspace.directory;
    self.native.spec.path = std.fmt.allocPrint(allocator, "{s}/native/{s}.zig", .{ directory, module.name }) catch |err| return self.failure.save(err);
    self.native.header = std.fmt.allocPrint(allocator, "{s}/native/{s}.h", .{ directory, module.name }) catch |err| return self.failure.save(err);
    const include = std.json.Stringify.valueAlloc(allocator, module.header.?, .{}) catch |err| return self.failure.save(err);
    const source = std.fmt.allocPrint(allocator, "#include {s}\n", .{include}) catch |err| return self.failure.save(err);

    artifacts.retain(context.io, allocator, self.native.header, source) catch |err| return self.failure.save(err);
}

pub fn translateNativeHeader(handle: *const anyopaque) Error!bool {
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
        .header = self.native.header,
    }) catch |err| return self.failure.save(err);

    const translated = translation.execute(context.io, command.arguments.items, &self.environment.?, self.native.spec.name) catch |err| return self.failure.save(err);

    self.native.spec.translated = translated;

    return translated != null;
}

pub fn writeNativeAdapter(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const adapter = compiler.zig.host.cAdapter(context.allocator) catch |err| return self.failure.save(err);

    defer context.allocator.free(adapter);
    artifacts.retain(context.io, context.allocator, self.native.spec.path, adapter) catch |err| return self.failure.save(err);
}

pub fn appendNativeModule(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.command.module(self.native.spec) catch |err| return self.failure.save(err);
}

pub fn abiViewCount(handle: *const anyopaque) u64 {
    return State.get(handle).abi.views.len;
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

fn appendSupport(self: *State, name: []const u8, source: []const u8, imports: []const []const u8) !void {
    const path = try std.fmt.allocPrint(self.context.allocator, "{s}/{s}", .{ self.workspace.directory, source });

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
