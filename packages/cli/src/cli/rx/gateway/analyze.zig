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
    root: []const u8 = undefined,
    owner: []const u8 = undefined,
    loaded: ?collection.Result = null,
    gateway: ?gateway.Result = null,
    services: ?services.Result = null,
    temporary: std.heap.ArenaAllocator,
    exports: []Export = &.{},
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.services) |*service| service.deinit();

        self.temporary.deinit();

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
    var state: State = .{ .allocator = allocator, .options = &options, .temporary = .init(allocator) };
    const reference = &state;

    defer state.deinit();

    const valid = @import("cli_source").analyze_gateway_application.executeIn(allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return if (valid) state.take() else null;
}

pub fn resolveGatewayOwner(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const project = &self.options.loaded.project;
    const allocator = self.allocator;
    self.root = std.fs.path.resolve(allocator, &.{project.root_dir}) catch |err| return self.failure.save(err);
    self.owner = std.fs.path.relative(allocator, self.root, null, self.root, project.entry) catch |err| return self.failure.save(err);

    if (collection.outside(self.owner)) return self.failure.save(error.RxEntryOutsideProject);
}

pub fn requireGatewaySource(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    if (self.options.loaded.config.library != null) return self.failure.save(error.GatewaySourceRequired);
}

pub fn collectGatewayDocuments(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const options = self.options;

    self.loaded = collection.load(self.allocator, .{
        .io = options.io,
        .root = self.root,
        .entry = self.owner,
        .writer = options.writer,
        .inputs = options.inputs,
        .project = options.loaded.project,
        .parse_cache = options.parse_cache,
    }) catch |err| return self.failure.save(err);

    return self.loaded != null;
}

pub fn analyzeGatewayDocument(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const loaded = &self.loaded.?;
    const source = loaded.data.gateway orelse return self.failure.save(error.ExpectedGateway);

    self.gateway = loaded.takeGateway() orelse gateway.analyze(self.allocator, .{ .owner = source.path, .node = source.node }) catch |err| return self.failure.save(err);

    const result = &self.gateway.?.value;

    if (result.* == .diagnostic) {
        const issue = result.diagnostic;

        self.options.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

pub fn reserveGatewayServices(handle: *const anyopaque) Error!u64 {
    const self = State.get(handle);
    const count = self.gateway.?.value.definition.service_routes.len;
    self.exports = self.temporary.allocator().alloc(Export, count) catch |err| return self.failure.save(err);

    return count;
}

pub fn recordGatewayService(handle: *const anyopaque, index: u64) void {
    const self = State.get(handle);
    const definition = &self.gateway.?.value.definition;
    const row: usize = @intCast(index);
    const service = definition.routes[definition.service_routes[row]].service;

    self.exports[row] = .{ .path = service, .source = service };
}

pub fn analyzeGatewayServices(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const options = self.options;
    var configured = options.loaded;

    configured.config.exports = self.exports;

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
