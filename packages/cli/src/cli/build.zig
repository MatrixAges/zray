const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("compile.zig");
const Loaded = @import("project.zig").Loaded;
const Paths = @import("toolchain.zig").Paths;
const Command = @import("build/command.zig");
const Staged = @import("build/staged.zig");
const Translation = @import("build/translation.zig");
const Response = @import("backend_protocol").Result;
const Bindings = @import("publication_host").application.Bindings;
const NodeSources = @import("node/resources.zig").Result;
const effects = @import("sources/effects.zig");
pub const Observed = @import("build/observed.zig");

pub const State = struct {
    context: *const Compile.Context,
    bundle: *const compiler.zig.ModuleBundle,
    project: *const Loaded,
    toolchain: Paths,
    command: Command,
    staged: ?Staged = null,
    environment: ?std.process.Environ.Map = null,
    translation: ?Translation = null,
    bindings: ?Bindings = null,
    response: ?Response = null,
    observed: ?Observed = null,
    failure: effects.Failure = .{},
    node_sources: ?NodeSources = null,
    node_library: ?[]const u8 = null,
    runner: ?[]const u8 = null,
    target: @import("cli_abi").layouts.@"zig:native_build_host".BackendTarget = undefined,
    configuration: []const u8 = undefined,
    abi: @import("abi.zig").Result = undefined,
    abi_views: @import("project/native_paths.zig").Abi = undefined,
    module: @import("cli_abi").layouts.@"zig:native_build_host".NativeBackendModule = undefined,
    workspace: @import("artifacts.zig").Prepared = undefined,
    native_names: [][]const u8 = undefined,
    settings_buffer: [Command.constants.settings_capacity][]const u8 = undefined,
    settings: []const []const u8 = undefined,
    native: PendingNative = undefined,
    pub const PendingNative = struct {
        spec: Command.Module,
        header: ?[]const u8,
    };
    pub fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }

    pub fn releaseSources(self: *State) void {
        if (self.runner) |runner| self.context.allocator.free(runner);
        if (self.node_sources) |*sources| sources.deinit();

        self.runner = null;
        self.node_sources = null;
    }

    pub fn releaseEnvironment(self: *State) void {
        if (self.environment) |*environment| environment.array_hash_map.deinit(environment.allocator);

        self.environment = null;
    }

    pub fn deinit(self: *State) void {
        self.releaseSources();

        if (self.observed) |*observed| observed.deinit();
        if (self.response) |*response| response.deinit();
        if (self.translation) |*translation| translation.deinit();

        self.releaseEnvironment();

        if (self.staged) |staged| staged.deinit(self.context.io);
    }
};
