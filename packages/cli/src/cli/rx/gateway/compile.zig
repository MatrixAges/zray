const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../../compile.zig");
const Loaded = @import("../../project.zig").Loaded;
const analyze = @import("analyze.zig");
const cache = @import("../../generation_cache.zig");
const toolchain = @import("../../toolchain.zig");
const native = @import("../../build/native.zig");
const effects = @import("../../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    context: *const Compile.Context,
    loaded: *const Loaded,
    analyzed: ?analyze.Result = null,
    linked: ?compiler.library.Result = null,
    configuration: compiler.zig.gateway.Options = undefined,
    cache: ?compiler.zig.GenerationCache = null,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    services: ?compiler.zig.LibraryBundle = null,
    bundle: ?compiler.zig.ModuleBundle = null,
    paths: toolchain.Paths = undefined,
    native_project: Loaded = undefined,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        const allocator = self.context.allocator;

        if (self.bundle) |*bundle| {
            if (bundle.runner) |runner| allocator.free(runner);

            bundle.deinit();
        }

        if (self.services) |*services| services.deinit();

        self.sources.deinit(allocator);

        if (self.cache) |*generation| generation.deinit();
        if (self.linked) |*linked| linked.deinit();
        if (self.analyzed) |*analyzed| analyzed.deinit();
    }
};

pub fn run(context: *const Compile.Context, loaded: *const Loaded) !Compile.Status {
    var state: State = .{ .context = context, .loaded = loaded };
    const entry = @import("cli_source").build_gateway_application;
    const settings = context.options.executionSettings();
    const reference = &state;

    const request: std.meta.Child(entry.Input) = .{
        .gateway = @ptrCast(&reference),
        .settings = &settings,
    };

    defer state.deinit();

    const outcome = entry.executeIn(context.allocator, &request) catch |err| return state.failure.unwrap(err);

    if (outcome.diagnostic) |message| try context.stderr.print("{s}\n", .{message});

    return native.status(outcome.status);
}

pub fn loadGatewayBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    self.analyzed = analyze.run(context.allocator, .{
        .io = context.io,
        .loaded = self.loaded.*,
        .writer = context.stderr,
        .inputs = if (context.watch) |attempt| attempt.inputs else null,
        .parse_cache = if (context.watch) |attempt| attempt.parse_cache else null,
    }) catch |err| return self.failure.save(err);

    return self.analyzed != null;
}

pub fn linkGatewayBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.linked = self.analyzed.?.link(self.context.allocator) catch |err| return self.failure.save(err);

    return self.linked != null;
}

pub fn bindGatewayBuildRoutes(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const definition = &self.analyzed.?.gateway.value.definition;
    const routes = compiler.zig.gateway.bindRoutes(self.context.allocator, definition, if (self.linked) |*library| library.exports else &.{}) catch |err| return self.failure.save(err);

    self.configuration = .{
        .routes = routes,
        .listen = definition.listen orelse @import("cli_source").gateway_default_listen.@"zx.constants".default_listen,
        .max_header_bytes = definition.max_header_bytes,
        .max_body_bytes = definition.max_body_bytes,
    };
}

pub fn openGatewayBuildCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.cache = cache.init(context.io, context.allocator, self.loaded.project.root_dir) catch |err| return self.failure.save(err);
}

pub fn collectGatewayBuildSources(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.sources = self.analyzed.?.services.?.collectSources(self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn emitGatewayBuildServices(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const options = &context.options;

    const emitted = compiler.emitLibraryVerified(context.allocator, .{
        .io = context.io,
        .sources = self.sources.items,
        .project = self.loaded.project,
        .generation_cache = if (options.cache) &self.cache.? else null,
        .solver = options.solver,
        .verification_allocator = @import("../../verify.zig").workspace_allocator,
        .writer = context.stderr,
    }, &self.linked.?) catch |err| return self.failure.save(err);

    if (emitted == .diagnostic) {
        defer emitted.diagnostic.deinit();
        context.stderr.print("{s}: {t}: {s}\n", .{ options.input, emitted.diagnostic.code, emitted.diagnostic.message }) catch |err| return self.failure.save(err);

        return false;
    }

    self.services = emitted.bundle;

    return true;
}

pub fn assembleGatewayBuild(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.bundle = compiler.zig.gateway.create(&self.linked.?, &self.services.?, self.configuration) catch |err| return self.failure.save(err);
    self.services = null;

    self.sources.deinit(self.context.allocator);

    self.sources = .empty;
}

pub fn assembleEmptyGatewayBuild(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.bundle = compiler.zig.gateway.empty(self.context.allocator, self.configuration) catch |err| return self.failure.save(err);
}

pub fn attachGatewayRunner(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.bundle.?.runner = compiler.zig.host.gateway(self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn reportGatewayBuildCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    cache.report(&self.cache.?, self.context.options, self.context.stderr) catch |err| return self.failure.save(err);
}

pub fn resolveGatewayToolchain(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.paths = toolchain.resolve(context.io, context.allocator, context.environment) catch |err| return self.failure.save(err);
}

pub fn resolveGatewayNativeProject(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const bundle = &self.bundle.?;

    self.native_project = @import("../../standard.zig").resolve(self.context.allocator, self.loaded.*, bundle.native_modules.import_names, self.paths.standard, bundle.modules) catch |err| return self.failure.save(err);
}

pub fn runGatewayBackend(handle: *const anyopaque) Error!native.RxStatus {
    const self = State.get(handle);
    const status = native.run(self.context, &self.bundle.?, &self.native_project, self.paths) catch |err| return self.failure.save(err);

    return native.sourceStatusAs(native.RxStatus, status);
}
