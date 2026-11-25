const std = @import("std");
const Build = @import("../build.zig");
const State = Build.State;
const Options = @import("../options.zig").Options;
const Command = @import("command.zig");
const artifacts = @import("../artifacts.zig");
const Error = @import("../sources/effects.zig").Error;

pub fn reserveNativeNames(handle: *const anyopaque) Error!u64 {
    const self = State.get(handle);
    const count = self.project.config.native_modules.len;
    self.native_names = self.context.allocator.alloc([]const u8, count) catch |err| return self.failure.save(err);

    return count;
}

pub fn recordNativeName(handle: *const anyopaque, index: u64) bool {
    const self = State.get(handle);
    const row: usize = @intCast(index);
    const module = &self.project.config.native_modules[row];

    self.native_names[row] = module.name;

    return module.header != null;
}

pub fn appendBackendPrefix(handle: *const anyopaque, libc: bool, library_paths: []const []const u8, wasm: bool) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const loaded = self.project;
    const cache = self.translation.?.cache;

    self.command.prefix(.{
        .tool = self.toolchain.executable,
        .library = self.toolchain.library,
        .node = context.options.host == .node,
        .wasm = wasm,
        .node_library = self.node_library,
        .server = if (self.staged == null) &.{
            .name = Build.Observed.artifact_name,
            .root = cache.cwd,
            .local = cache.local,
            .global = cache.global,
            .assembly = context.options.assembly != null,
        } else null,
        .files = if (self.staged) |staged| &.{ .binary = staged.binary, .assembly = staged.assembly } else null,
        .libraries = loaded.config.libraries,
        .library_paths = library_paths,
        .libc = libc,
    }) catch |err| return self.failure.save(err);
}

pub fn appendBackendEntry(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const allocator = self.context.allocator;
    const options = self.context.options;
    const target = targetOptions(allocator, options) catch |err| return self.failure.save(err);

    self.settings = Command.settings(allocator, &self.settings_buffer, target) catch |err| return self.failure.save(err);

    self.command.entry(.{
        .settings = self.settings,
        .directory = self.workspace.directory,
        .node = options.host == .node,
        .state = self.bundle.state_module,
        .imports = self.bundle.entry.imports,
        .natives = self.native_names,
    }) catch |err| return self.failure.save(err);
}

pub fn writeBackendCommand(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const manifest = std.json.Stringify.valueAlloc(context.allocator, self.command.arguments.items, .{ .whitespace = .indent_2 }) catch |err| return self.failure.save(err);
    const path = std.fs.path.join(context.allocator, &.{ self.workspace.directory, "command.json" }) catch |err| return self.failure.save(err);

    artifacts.write(context.io, path, manifest) catch |err| return self.failure.save(err);
}

fn targetOptions(allocator: std.mem.Allocator, options: Options) !Command.Settings {
    const builtin = @import("builtin");
    const host = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
    const target = options.target orelse if (!std.mem.eql(u8, host, @import("bundle").zig_host)) try builtin.target.zigTriple(allocator) else null;

    return .{ .optimize = @tagName(options.optimize), .target = target, .cpu = options.cpu };
}
