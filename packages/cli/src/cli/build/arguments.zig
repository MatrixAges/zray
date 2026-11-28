const std = @import("std");
const Build = @import("../build.zig");
const State = Build.State;
const artifacts = @import("../artifacts.zig");
const Error = @import("../sources/effects.zig").Error;
const Options = @import("cli_abi").layouts.@"zig:native_build_host".CommandOptions;

pub fn readBackendCommandOptions(handle: *const anyopaque) Error!*const Options {
    const self = State.get(handle);
    const options = self.context.options;
    const cache = self.translation.?.cache;
    const builtin = @import("builtin");
    const host = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

    const target = options.target orelse if (!std.mem.eql(u8, host, @import("bundle").zig_host))
        builtin.target.zigTriple(self.context.allocator) catch |err| return self.failure.save(err)

    else
        null;

    if (self.staged) |staged| {
        self.command_files = .{ .binary = staged.binary, .assembly = staged.assembly };
    } else {
        self.command_server = .{
            .name = Build.Observed.artifact_name,
            .root = cache.cwd,
            .local = cache.local,
            .global = cache.global,
            .assembly = options.assembly != null,
        };
    }

    self.command_options = .{
        .directory = self.workspace.directory,
        .module_paths = self.workspace.module_paths,
        .tool = self.toolchain.executable,
        .library = self.toolchain.library,
        .local = cache.local,
        .global = cache.global,
        .node_library = self.node_library,
        .server = if (self.staged == null) &self.command_server else null,
        .files = if (self.staged != null) &self.command_files else null,
        .optimize = @tagName(options.optimize),
        .target = target,
        .cpu = options.cpu,
        .libraries = self.project.config.libraries,
        .state = self.bundle.state_module,
        .imports = self.bundle.entry.imports,
    };

    return &self.command_options;
}

pub fn writeBackendCommand(handle: *const anyopaque, arguments: []const []const u8) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const manifest = std.json.Stringify.valueAlloc(context.allocator, arguments, .{ .whitespace = .indent_2 }) catch |err| return self.failure.save(err);
    const path = std.fs.path.join(context.allocator, &.{ self.workspace.directory, "command.json" }) catch |err| return self.failure.save(err);

    artifacts.write(context.io, path, manifest) catch |err| return self.failure.save(err);
}
