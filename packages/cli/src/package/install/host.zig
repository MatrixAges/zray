const std = @import("std");
const workspace = @import("../workspace.zig");
const Options = @import("options.zig");
const model = @import("model.zig");
const files = @import("files.zig");
pub const fresh = @import("fresh/storage.zig");
pub const archive = @import("fresh/archive_io.zig");
pub const locked = @import("locked/storage.zig");
const Fresh = fresh.State;
const pkgs = @import("pkgs");
pub const Error = error{InstallHostFailure};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    root: []const u8,
    cache: []const u8,
    members: []const workspace.Package,
    previous: ?files.Loaded,
    reuse: bool,
    prepared: model.Prepared = undefined,
    publication: files.Publication = undefined,
    fresh: Fresh = .{},
    scratch: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    failure: ?anyerror = null,
    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options, environment: *const std.process.Environ.Map) !State {
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(options.path) orelse ".", allocator);
        const discovered = try workspace.load(io, allocator, options.path);

        if (discovered.diagnostic != null) return error.InvalidWorkspace;

        const cache = try @import("toolchain_cache").root(allocator, environment);
        const previous = try files.load(io, allocator, root, null);

        return .{
            .io = io,
            .allocator = allocator,
            .options = options,
            .root = root,
            .cache = cache,
            .members = discovered.packages,
            .previous = previous,
            .reuse = if (previous) |lock| model.matchesWorkspace(lock.lock, discovered.packages) else false,
        };
    }

    pub fn deinit(self: *State) void {
        self.scratch.deinit();

        if (self.fresh.archives) |*archives| archives.table.deinit();
    }

    pub fn get(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }

    pub fn fail(self: *State, err: anyerror) Error {
        self.failure = err;

        return error.InstallHostFailure;
    }
    pub fn physicalPath(self: *State, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
    }

    pub fn fetch(self: *State, release: pkgs.Index.Release, base: []const u8) ![]const u8 {
        return @import("package_store").prepare(self.io, self.allocator, release, base, self.cache, self.options.offline);
    }
};

pub fn currentWorkspaceMatches(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const current = workspace.load(self.io, self.allocator, self.options.path) catch |err| return self.fail(err);

    return current.diagnostic == null and model.matchesWorkspace(self.prepared.lock, current.packages);
}

pub fn renderInstallation(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.publication = files.render(self.allocator, self.prepared) catch |err| return self.fail(err);

    return self.publication.fits();
}

pub fn publishMapping(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    files.writeMapping(self.io, self.allocator, self.root, &self.publication) catch |err| return self.fail(err);
}

pub fn lockUnchanged(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    return files.lockUnchanged(self.io, self.allocator, self.root, self.publication.lock) catch |err| self.fail(err);
}

pub fn publishLock(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    files.writeLock(self.io, self.allocator, self.root, self.publication.lock) catch |err| return self.fail(err);
}
