const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Loaded = @import("../project.zig").Loaded;
const Paths = @import("../toolchain.zig").Paths;
const build = @import("../build.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
pub const Status = @import("rx_execution_abi").native.@"zig:rx_execution_host".Status;

const State = struct {
    context: *const Compile.Context,
    bundle: *const compiler.zig.ModuleBundle,
    project: *const Loaded,
    toolchain: Paths,
    observed: ?build.Observed = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
};

pub fn run(context: *const Compile.Context, bundle: *const compiler.zig.ModuleBundle, project: *const Loaded, toolchain: Paths) !Compile.Status {
    var state: State = .{ .context = context, .bundle = bundle, .project = project, .toolchain = toolchain };
    const reference = &state;

    defer if (state.observed) |*observed| observed.deinit();

    const result = @import("cli_source").build_native_application.executeIn(context.allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

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

pub fn watchesNativeBuild(handle: *const anyopaque) bool {
    return State.get(handle).context.watch != null;
}

pub fn runNativeBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    return build.run(context.io, context.allocator, self.bundle.*, context.options, self.project.*, self.toolchain, context.environment) catch |err| self.failure.save(err);
}

pub fn prepareObservedNativeBuild(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.watch.?.prepareBackend(self.context.io) catch |err| return self.failure.save(err);
}

pub fn runObservedNativeBuild(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.observed = build.runObserved(context.io, context.allocator, self.bundle.*, context.options, self.project.*, self.toolchain, context.environment, context.watch.?.inputs) catch |err| return self.failure.save(err);
}

pub fn finishObservedNativeInputs(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.watch.?.finishBackend(self.observed.?.input_paths) catch |err| return self.failure.save(err);
}

pub fn reportObservedNativeBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const response = &self.observed.?.response;
    const writer = self.context.stderr;

    writer.writeAll(response.stderr) catch |err| return self.failure.save(err);
    response.diagnostics.renderToWriter(.{}, writer) catch |err| return self.failure.save(err);

    return response.succeeded;
}

pub fn requireObservedNativeInputs(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    if (!self.observed.?.response.inputs_complete) return self.failure.save(error.IncompleteBackendInputs);
}

pub fn publishObservedNativeBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    return self.observed.?.publish(context.io, context.allocator, context.watch.?.inputs, context.options) catch |err| self.failure.save(err);
}
