const std = @import("std");
const host = @import("publication_host");
const inventory = host.inventory;
const rule = @import("cli_source").library_stage_write;
const constants = @import("cli_source").library_publication_constants.@"zx.constants";
const storage = @import("stage/storage.zig");
const Error = storage.Error;
pub const Request = storage.Request;
pub const resources = @import("resources.zig");
pub const output = @import("stage/output.zig");

pub fn write(request: Request) ![]const inventory.File {
    var failure: host.Failure = .{};

    var native: resources.State = .{
        .io = request.io,
        .allocator = request.allocator,
        .directory = request.directory,
        .loaded = request.loaded,
        .inputs = request.inputs,
        .failure = &failure,
    };

    var state: storage.State = .{ .request = request, .resources = &native, .failure = &failure };
    const stage_ref = &state;
    const native_ref = &native;
    var paths: @import("../project/native_paths.zig").Paths = undefined;
    var position = [1]u64{0};
    const cursor: []u64 = &position;

    paths.init(request.loaded, &request.allocator);

    rule.executeIn(request.allocator, &.{
        .stage = @ptrCast(&stage_ref),
        .resources = &.{
            .resources = @ptrCast(&native_ref),
            .setup = &paths.setup,
            .count = request.loaded.config.native_modules.len,
            .cursor = @ptrCast(&cursor),
        },
    }) catch |err| return failure.unwrap(err);

    return state.managed;
}

pub fn prepareStageAbi(handle: *const anyopaque) Error!void {
    const self = storage.State.get(handle);
    const request = self.request;

    self.abi = @import("../abi.zig").create(request.allocator, request.bundle, request.loaded) catch |err| return self.failure.save(err);
}

pub fn prepareStageLayout(handle: *const anyopaque) Error!void {
    const self = storage.State.get(handle);
    const request = self.request;
    const config = request.loaded.config;
    const plan = @import("publication/layout.zig").create(request.allocator, config, request.library, request.bundle) catch |err| return self.failure.save(err);

    self.layout = plan;

    self.config = .{
        .name = plan.name,
        .version = plan.version,
        .library = constants.library_file,
        .exports = plan.exports,
        .private = config.private,
        .native_modules = self.resources.native_modules,
        .libraries = config.libraries,
        .library_paths = self.resources.library_paths,
    };
}

pub fn collectStageInventory(handle: *const anyopaque) Error!void {
    const self = storage.State.get(handle);
    const request = self.request;

    self.managed = inventory.collect(request.io, request.allocator, request.directory) catch |err| return self.failure.save(err);
}
