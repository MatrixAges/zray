const std = @import("std");
const compiler = @import("compiler");
const gateway = @import("rx_analysis").gateway;
const collection = @import("../collection.zig");
const services = @import("../../library/analyze.zig");
const Loaded = @import("../../project.zig").Loaded;
const Inputs = @import("watch_inputs").Inputs;
const Export = @import("../../../package/manifest/model.zig").Export;
const effects = @import("../../sources/effects.zig");
const Error = effects.Error;
const abi = @import("cli_abi");
const GatewayRoutes = abi.layouts.@"zig:rx_execution_host".GatewayRoutes;
const GatewayService = abi.native.@"zig:rx_execution_host".GatewayService;
pub const Options = struct { io: std.Io, loaded: Loaded, writer: *std.Io.Writer, inputs: ?*Inputs = null, parse_cache: ?*compiler.project.ParseCache = null };

pub const Result = struct {
    gateway: gateway.Result,
    services: ?services.Result,
    pub fn deinit(self: *Result) void {
        if (self.services) |*value| value.deinit();

        self.gateway.deinit();

        self.* = undefined;
    }

    pub fn link(self: *Result, allocator: std.mem.Allocator) !?compiler.library.Result {
        if (self.services) |*value| return try value.link(allocator);

        return null;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    options: *const Options,
    loaded: ?collection.Result = null,
    gateway: ?gateway.Result = null,
    services: ?services.Result = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.services) |*service| service.deinit();
        if (self.gateway) |*analyzed| analyzed.deinit();
        if (self.loaded) |*loaded| loaded.deinit();
    }

    fn take(self: *State) Result {
        const result: Result = .{ .gateway = self.gateway.?, .services = self.services };
        self.gateway = null;
        self.services = null;

        return result;
    }
};

pub fn run(allocator: std.mem.Allocator, options: Options) !?Result {
    var state: State = .{ .allocator = allocator, .options = &options };
    const reference = &state;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();
    defer state.deinit();

    const outcome = @import("cli_source").analyze_gateway_application.executeIn(arena.allocator(), &.{
        .analysis = @ptrCast(&reference),
        .has_library = options.loaded.config.library != null,
        .root = options.loaded.project.root_dir,
        .entry = options.loaded.project.entry,
    }) catch |err| return state.failure.unwrap(err);

    return switch (outcome) {
        .Valid => state.take(),
        .Invalid => null,
        .SourceRequired => error.GatewaySourceRequired,
        .OutsideProject => error.RxEntryOutsideProject,
    };
}

pub fn collectGatewayDocuments(handle: *const anyopaque, root: []const u8, owner: []const u8) Error!bool {
    const self = State.get(handle);
    const options = self.options;

    self.loaded = collection.load(self.allocator, .{
        .io = options.io,
        .root = root,
        .entry = owner,
        .writer = options.writer,
        .inputs = options.inputs,
        .project = options.loaded.project,
        .parse_cache = options.parse_cache,
    }) catch |err| return self.failure.save(err);

    return self.loaded != null;
}

pub fn analyzeGatewayDocument(allocator: std.mem.Allocator, handle: *const anyopaque) (Error || std.mem.Allocator.Error)!?*const GatewayRoutes {
    const self = State.get(handle);
    const loaded = &self.loaded.?;
    const source = loaded.data.gateway orelse return self.failure.save(error.ExpectedGateway);

    self.gateway = loaded.takeGateway() orelse gateway.analyze(self.allocator, .{ .owner = source.path, .node = source.node }) catch |err| return self.failure.save(err);

    const result = &self.gateway.?.value;

    if (result.* == .diagnostic) {
        const issue = result.diagnostic;

        self.options.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

        return null;
    }

    const definition = &result.definition;
    const route_services = try allocator.alloc([]const u8, definition.routes.len);

    for (definition.routes, 0..) |route, index| {
        route_services[index] = route.service;
    }

    const routes = try allocator.create(GatewayRoutes);

    routes.* = .{
        .route_services = route_services,
        .service_routes = definition.service_routes,
    };

    return routes;
}

pub fn analyzeGatewayServices(handle: *const anyopaque, service_rows: []const GatewayService) Error!bool {
    const self = State.get(handle);
    const options = self.options;
    const exports = self.allocator.alloc(Export, service_rows.len) catch |err| return self.failure.save(err);

    defer self.allocator.free(exports);

    for (service_rows, 0..) |service, index| {
        exports[index] = .{ .path = service.name, .source = service.source };
    }

    var configured = options.loaded;

    configured.config.exports = exports;

    self.services = services.run(self.allocator, .{
        .io = options.io,
        .backing = self.allocator,
        .loaded = configured,
        .writer = options.writer,
        .inputs = options.inputs,
        .parse_cache = options.parse_cache,
    }) catch |err| return self.failure.save(err);

    return self.services != null;
}
