const std = @import("std");
const backend = @import("backend_protocol");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Loaded = @import("../project.zig").Loaded;
const Paths = @import("../toolchain.zig").Paths;
const Build = @import("../build.zig");
const State = Build.State;
const effects = @import("../sources/effects.zig");
const memory = @import("zx").memory;
const Error = effects.Error;
pub const preparation = @import("prepare.zig");
pub const command = @import("arguments.zig");
pub const modules = @import("modules.zig");
pub const Status = @import("cli_abi").native.@"zig:native_build_host".Status;
pub const CompilationStatus = @import("cli_abi").native.@"zig:compilation_host".Status;
pub const RxStatus = @import("cli_abi").native.@"zig:rx_execution_host".Status;

pub fn run(context: *const Compile.Context, bundle: *const compiler.zig.ModuleBundle, project: *const Loaded, toolchain: Paths) !Compile.Status {
    var state: State = .{
        .context = context,
        .bundle = bundle,
        .project = project,
        .toolchain = toolchain,
    };

    const entry = @import("cli_source").build_native_application;
    const reference = &state;
    var arena = std.heap.ArenaAllocator.init(context.allocator);

    defer arena.deinit();

    const scratch = arena.allocator();
    const native_modules = project.config.native_modules;
    const generated_names = memory.borrowTextColumn("name", bundle.modules);
    const generated_imports = memory.borrowReadColumn([]const []const u8, "imports", bundle.modules);
    const native_imports = memory.borrowReadColumn([]const []const u8, "dependencies", native_modules);
    var previous_backend: []const []const u8 = &.{};
    var observed_paths: []const []const u8 = &.{};

    if (context.watch) |watch| {
        previous_backend = watch.previous_backend;

        const observed_list = try scratch.alloc([]const u8, watch.inputs.entries.count());
        var entries = watch.inputs.entries.iterator();
        var index: usize = 0;

        while (entries.next()) |item| : (index += 1) {
            observed_list[index] = item.key_ptr.*;
        }

        observed_paths = observed_list;
    }

    const native_paths = @import("../project/native_paths.zig");
    var paths: native_paths.Paths = undefined;
    var module_columns: native_paths.NativeModules = undefined;

    paths.init(project, &context.allocator);
    module_columns.init(project);

    const invocation: std.meta.Child(entry.Input) = .{
        .build = @ptrCast(&reference),
        .node = context.options.host == .node,
        .observed = context.watch != null,
        .previous_backend = previous_backend,
        .observed_paths = observed_paths,
        .generated = &.{
            .count = bundle.modules.len,
            .names = @ptrCast(&generated_names),
            .imports = @ptrCast(&generated_imports),
        },
        .native = &.{
            .build = @ptrCast(&reference),
            .observed = context.watch != null,
            .count = native_modules.len,
            .imports = @ptrCast(&native_imports),
            .modules = &module_columns.view,
            .setup = &paths.setup,
            .abi_views = &state.abi_views.view,
        },
    };

    defer state.deinit();

    const result = entry.executeIn(context.allocator, &invocation, context.io) catch |err| return state.failure.unwrap(err);

    return switch (result) {
        .Success => .success,
        .Failed => .failed,
        .BackendFailed => .backend_failed,
        .Retry => .retry,
        .IncompleteInputs => error.IncompleteBackendInputs,
    };
}

pub fn status(result: anytype) Compile.Status {
    return switch (result) {
        .Success => .success,
        .Failed => .failed,
        .BackendFailed => .backend_failed,
        .Retry => .retry,
    };
}

pub fn sourceStatusAs(comptime Target: type, result: Compile.Status) Target {
    return switch (result) {
        .success => .Success,
        .failed => .Failed,
        .backend_failed => .BackendFailed,
        .retry => .Retry,
    };
}

pub fn sourceStatus(result: Compile.Status) Status {
    return sourceStatusAs(Status, result);
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

pub fn spawnStagedBackend(handle: *const anyopaque, arguments: []const []const u8) Error!bool {
    const self = State.get(handle);
    const io = self.context.io;

    var child = std.process.spawn(io, .{
        .argv = arguments,
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

pub fn spawnObservedBackend(handle: *const anyopaque, arguments: []const []const u8) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.response = backend.process.run(context.io, context.allocator, arguments, &self.environment.?, .application) catch |err| return self.failure.save(err);
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

pub fn reportObservedNativeBuild(handle: *const anyopaque) Error!?bool {
    const self = State.get(handle);
    const response = &self.observed.?.response;
    const writer = self.context.stderr;

    response.report(writer) catch |err| return self.failure.save(err);

    if (!response.succeeded) return null;

    return response.inputs_complete;
}

pub fn publishObservedNativeBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    return self.observed.?.publish(context.io, context.allocator, context.watch.?.inputs, context.options) catch |err| self.failure.save(err);
}
