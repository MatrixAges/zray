const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const Directory = @import("../publication/directory.zig");
const effects = @import("../publication/effects.zig");
const rule = @import("cli_source").native_directory_files;
const abi = @import("publication_abi");
const ResourceEntry = abi.layouts.@"zig:publication_host".ResourceEntry;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Error = effects.Error;

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn files(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inputs: ?*Inputs) ![]const []const u8 {
    var failure: effects.Failure = .{};
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var walk: Directory = .{ .io = io, .allocator = arena.allocator(), .failure = &failure, .source = path, .inputs = inputs };

    defer walk.deinit();

    const state = &walk;
    var discovered: StoreState = &.{ .paths = &.{} };
    var host: StoreHost = .{ .store_0 = &discovered };
    const outcome = rule.execute(&arena, &.{ .walk = @ptrCast(&state), .running = true }, &host) catch |err| return failure.unwrap(err);

    if (!outcome.supported) return error.UnsupportedNativeResource;

    const result = try allocator.alloc([]const u8, outcome.paths.len);
    var initialized: usize = 0;

    errdefer {
        for (result[0..initialized]) |item| allocator.free(item);

        allocator.free(result);
    }

    for (outcome.paths, 0..) |item, index| {
        result[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }

    return result;
}

pub fn resourceRoot(handle: *const anyopaque) Error!*const ResourceEntry {
    const directory = effects.state(Directory, handle);

    if (directory.inputs) |observed| observed.add(directory.io, directory.source) catch |err| return directory.failure.save(err);

    const stat = std.Io.Dir.cwd().statFile(directory.io, directory.source, .{}) catch |err| return directory.failure.save(err);

    directory.resource_view = .{
        .kind = Directory.resourceKind(stat.kind),
        .path = directory.source,
    };

    return &directory.resource_view;
}

pub fn nextResource(handle: *const anyopaque) Error!*const ResourceEntry {
    const directory = effects.state(Directory, handle);
    const maybe_kind = try directory.advance();

    if (maybe_kind == null) {
        directory.resource_view = .{ .kind = .End, .path = "" };

        return &directory.resource_view;
    }

    const kind = maybe_kind.?;

    const path = if (kind != .directory or directory.inputs != null)
        std.fs.path.join(directory.allocator, &.{ directory.source, directory.path }) catch |err| return directory.failure.save(err)

    else
        "";

    directory.resource_view = .{
        .kind = Directory.resourceKind(kind),
        .path = path,
    };

    return &directory.resource_view;
}

pub fn observeResource(handle: *const anyopaque, path: []const u8, is_directory: bool) Error!void {
    const directory = effects.state(Directory, handle);
    const inputs = directory.inputs orelse return;

    (if (is_directory) inputs.addDirectory(directory.io, path) else inputs.add(directory.io, path)) catch |err| return directory.failure.save(err);
}

pub fn resourceLinkIsFile(handle: *const anyopaque, path: []const u8) Error!bool {
    const directory = effects.state(Directory, handle);
    const stat = std.Io.Dir.cwd().statFile(directory.io, path, .{}) catch |err| return directory.failure.save(err);

    return stat.kind == .file;
}
