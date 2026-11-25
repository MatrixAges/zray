const std = @import("std");
const backend = @import("backend_protocol");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Loaded = @import("../project.zig").Loaded;
const Paths = @import("../toolchain.zig").Paths;
const Build = @import("../build.zig");
const State = Build.State;
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
pub const preparation = @import("prepare.zig");
pub const command = @import("arguments.zig");
pub const modules = @import("modules.zig");
pub const Status = @import("cli_abi").native.@"zig:rx_execution_host".Status;

pub fn run(context: *const Compile.Context, bundle: *const compiler.zig.ModuleBundle, project: *const Loaded, toolchain: Paths) !Compile.Status {
    var state: State = .{
        .context = context,
        .bundle = bundle,
        .project = project,
        .toolchain = toolchain,
        .command = .{ .allocator = context.allocator },
    };

    const entry = @import("cli_source").build_native_application;
    const reference = &state;
    var paths: @import("../project/native_paths.zig").Paths = undefined;
    var position = [1]u64{0};
    var cursor: []u64 = &position;

    paths.init(project, &context.allocator);

    const invocation: std.meta.Child(entry.Input) = .{
        .build = @ptrCast(&reference),
        .node = context.options.host == .node,
        .observed = context.watch != null,
        .native = &.{
            .build = @ptrCast(&reference),
            .observed = context.watch != null,
            .count = project.config.native_modules.len,
            .cursor = @ptrCast(&cursor),
            .setup = &paths.setup,
            .abi_views = &state.abi_views.view,
        },
    };

    defer state.deinit();

    const result = entry.executeIn(context.allocator, &invocation) catch |err| return state.failure.unwrap(err);

    return status(result);
}

pub fn status(result: Status) Compile.Status {
    return switch (result) {
        .Success => .success,
        .Failed => .failed,
        .BackendFailed => .backend_failed,
        .Retry => .retry,
    };
}

pub fn sourceStatus(result: Compile.Status) Status {
    return switch (result) {
        .success => .Success,
        .failed => .Failed,
        .backend_failed => .BackendFailed,
        .retry => .Retry,
    };
}

pub fn createStagedBindings(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const bindings = @import("../node/bindings.zig").create(context.allocator, self.bundle, context.options) catch |err| return self.failure.save(err);

    bindings.check(context.io, context.allocator, context.options.assembly) catch |err| return self.failure.save(err);

    self.bindings = bindings;
}

pub fn openStagedOutput(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.staged = @import("staged.zig").init(context.io, context.allocator, context.options) catch |err| return self.failure.save(err);
}

pub fn openBackendEnvironment(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const allocator = context.allocator;
    var entries = context.environment.array_hash_map.clone(allocator) catch |err| return self.failure.save(err);

    errdefer entries.deinit(allocator);
    entries.put(allocator, backend.constants.library_environment_key, self.toolchain.library) catch |err| return self.failure.save(err);

    self.environment = .{ .allocator = allocator, .array_hash_map = entries };
}

pub fn openBackendTranslation(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const cache = Build.Observed.Cache.init(context.io, context.allocator, context.environment) catch |err| return self.failure.save(err);
    self.translation = .{ .arena = .init(context.allocator), .cache = cache };
}

pub fn reportStagedTranslationFailure(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const failure = &self.translation.?.pending.?;
    var buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(self.context.io, &buffer);

    failure.report(&stderr.interface) catch |err| return self.failure.save(err);
    stderr.interface.flush() catch |err| return self.failure.save(err);
}

pub fn spawnStagedBackend(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const io = self.context.io;

    var child = std.process.spawn(io, .{
        .argv = self.command.arguments.items,
        .environ_map = &self.environment.?,
    }) catch |err| return self.failure.save(err);

    const termination = child.wait(io) catch |err| return self.failure.save(err);

    return termination == .exited and termination.exited == 0;
}

pub fn retainStagedBindings(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const bindings = &self.bindings.?;

    bindings.check(context.io, context.allocator, context.options.assembly) catch |err| return self.failure.save(err);
    bindings.stage(context.io, context.allocator, std.fs.path.dirname(self.staged.?.binary).?) catch |err| return self.failure.save(err);
}

pub fn publishStagedBackend(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.staged.?.publish(context.io, context.allocator, context.options) catch |err| return self.failure.save(err);
}

pub fn spawnObservedBackend(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.response = backend.process.run(context.io, context.allocator, self.command.arguments.items, &self.environment.?, .application) catch |err| return self.failure.save(err);
}

pub fn takeTranslationFailure(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.response = self.translation.?.pending.?;
    self.translation.?.pending = null;
}

pub fn resolveObservedNativeInputs(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const translation = &self.translation.?;
    const watch = context.watch.?;

    self.observed = Build.Observed.resolveBatches(context.io, &self.response.?, translation.responses.items, translation.cache, self.toolchain.library, context.options, watch.inputs, watch.backend_owner.allocator()) catch |err| return self.failure.save(err);
    self.response = null;

    translation.deinit();

    self.translation = null;

    self.releaseEnvironment();
}

pub fn createObservedBindings(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const observed = &self.observed.?;

    observed.bindings = @import("../node/bindings.zig").create(observed.response.arena.allocator(), self.bundle, self.context.options) catch |err| return self.failure.save(err);
}

pub fn reportObservedNativeBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const response = &self.observed.?.response;
    const writer = self.context.stderr;

    response.report(writer) catch |err| return self.failure.save(err);

    return response.succeeded;
}

pub fn observedInputsComplete(handle: *const anyopaque) bool {
    return State.get(handle).observed.?.response.inputs_complete;
}

pub fn rejectIncompleteBackendInputs(handle: *const anyopaque) Error!void {
    return State.get(handle).failure.save(error.IncompleteBackendInputs);
}

pub fn publishObservedNativeBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    return self.observed.?.publish(context.io, context.allocator, context.watch.?.inputs, context.options) catch |err| self.failure.save(err);
}
