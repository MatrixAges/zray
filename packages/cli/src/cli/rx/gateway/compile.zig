const std = @import("std");
const compiler = @import("compiler");
const analyze = @import("analyze.zig");
const State = @import("../compile.zig").State;
const Error = @import("../../sources/effects.zig").Error;

pub const Build = struct {
    analyzed: ?analyze.Result = null,
    linked: ?compiler.library.Result = null,
    configuration: compiler.zig.gateway.Options = undefined,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    services: ?compiler.zig.LibraryBundle = null,
    pub fn deinit(self: *Build, allocator: std.mem.Allocator) void {
        if (self.services) |*services| services.deinit();

        self.sources.deinit(allocator);

        if (self.linked) |*linked| linked.deinit();
        if (self.analyzed) |*analyzed| analyzed.deinit();
    }
};

pub fn loadGatewayBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    self.gateway = .{};

    const build = &self.gateway.?;

    build.analyzed = analyze.run(context.allocator, .{
        .io = context.io,
        .loaded = self.loaded,
        .writer = context.stderr,
        .inputs = if (context.watch) |attempt| attempt.inputs else null,
        .parse_cache = if (context.watch) |attempt| attempt.parse_cache else null,
    }) catch |err| return self.failure.save(err);

    return build.analyzed != null;
}

pub fn linkGatewayBuild(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const build = &self.gateway.?;

    build.linked = build.analyzed.?.link(self.context.allocator) catch |err| return self.failure.save(err);

    return build.linked != null;
}

pub fn bindGatewayBuildRoutes(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const build = &self.gateway.?;
    const definition = &build.analyzed.?.gateway.value.definition;
    const routes = compiler.zig.gateway.bindRoutes(self.context.allocator, definition, if (build.linked) |*library| library.exports else &.{}) catch |err| return self.failure.save(err);

    build.configuration = .{
        .routes = routes,
        .listen = definition.listen orelse @import("cli_source").gateway_default_listen.@"zx.constants".default_listen,
        .max_header_bytes = definition.max_header_bytes,
        .max_body_bytes = definition.max_body_bytes,
    };
}

pub fn collectGatewayBuildSources(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const build = &self.gateway.?;

    build.sources = build.analyzed.?.services.?.collectSources(self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn emitGatewayBuildServices(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const options = &context.options;
    const build = &self.gateway.?;

    const emitted = compiler.emitLibraryVerified(context.allocator, .{
        .io = context.io,
        .sources = build.sources.items,
        .project = self.loaded.project,
        .generation_cache = if (options.cache) &self.cache.? else null,
        .solver = options.solver,
        .verification_allocator = @import("../../verify.zig").workspace_allocator,
        .writer = context.stderr,
    }, &build.linked.?) catch |err| return self.failure.save(err);

    if (emitted == .diagnostic) {
        defer emitted.diagnostic.deinit();
        context.stderr.print("{s}: {t}: {s}\n", .{ options.input, emitted.diagnostic.code, emitted.diagnostic.message }) catch |err| return self.failure.save(err);

        return false;
    }

    build.services = emitted.bundle;

    return true;
}

pub fn assembleGatewayBuild(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const build = &self.gateway.?;

    self.bundle = compiler.zig.gateway.create(&build.linked.?, &build.services.?, build.configuration) catch |err| return self.failure.save(err);
    build.services = null;

    build.sources.deinit(self.context.allocator);

    build.sources = .empty;
}

pub fn assembleEmptyGatewayBuild(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.bundle = compiler.zig.gateway.empty(self.context.allocator, self.gateway.?.configuration) catch |err| return self.failure.save(err);
}

pub fn attachGatewayRunner(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.bundle.?.runner = compiler.zig.host.gateway(self.context.allocator) catch |err| return self.failure.save(err);
}
