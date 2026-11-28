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
    const directory = try std.Io.Dir.cwd().openDir(request.io, request.directory, .{});

    defer directory.close(request.io);

    var failure: host.Failure = .{};
    const modules = request.loaded.config.native_modules;

    const native: resources.State = .{
        .io = request.io,
        .allocator = request.allocator,
        .directory = request.directory,
        .inputs = request.inputs,
        .failure = &failure,
        .native_modules = try request.allocator.dupe(@import("../project.zig").NativeModule, modules),
        .dependencies = try request.allocator.alloc(resources.Dependency, modules.len),
    };

    var state: storage.State = .{ .request = request, .resources = native, .failure = &failure, .disk = .{ .io = request.io, .directory = directory } };
    const stage_ref = &state;
    const columns = @import("../project/native_paths.zig");
    var paths: columns.Paths = undefined;
    var native_columns: columns.NativeModules = undefined;

    paths.init(request.loaded, &request.allocator);
    native_columns.init(request.loaded);

    rule.executeIn(request.allocator, &.{
        .stage = @ptrCast(&stage_ref),
        .files = &state.files,
        .resources = &.{
            .resources = @ptrCast(&stage_ref),
            .directory = request.directory,
            .setup = &paths.setup,
            .modules = &native_columns.view,
            .count = modules.len,
        },
    }, request.io) catch |err| return failure.unwrap(err);

    return state.managed;
}

pub fn prepareStageAbi(handle: *const anyopaque) Error!void {
    const self = storage.State.get(handle);
    const request = self.request;

    self.abi = @import("../abi.zig").create(request.allocator, request.bundle, request.loaded) catch |err| return self.failure.save(err);
}

pub fn prepareStageLayout(handle: *const anyopaque, library_paths: []const []const u8) Error!void {
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
        .library_paths = library_paths,
    };

    self.borrowFiles();
}

pub fn collectStageInventory(handle: *const anyopaque) Error!void {
    const self = storage.State.get(handle);
    const request = self.request;

    self.managed = inventory.collect(request.io, request.allocator, request.directory) catch |err| return self.failure.save(err);
}
