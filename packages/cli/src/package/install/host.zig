const std = @import("std");
const workspace = @import("../workspace.zig");
const Options = @import("options.zig");
const model = @import("model.zig");
const files = @import("files.zig");
const pkgs = @import("pkgs");
const Rendered = @import("cli_abi").layouts.@"zig:installation_host".Rendered;

const SessionLock = struct {
    lock: pkgs.Lock,
    source: ?[]const u8 = null,
};

pub const Error = error{InstallHostFailure};

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    root: []const u8,
    cache: []const u8,
    members: []const workspace.Package,
    failure: *?anyerror,
    lock: ?SessionLock = null,
    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options, environment: *const std.process.Environ.Map, failure: *?anyerror) !Context {
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(options.path) orelse ".", allocator);
        const discovered = try workspace.load(io, allocator, options.path);

        if (discovered.diagnostic != null) return error.InvalidWorkspace;

        const cache = try @import("toolchain_cache").root(allocator, environment);

        return .{
            .io = io,
            .allocator = allocator,
            .options = options,
            .root = root,
            .cache = cache,
            .members = discovered.packages,
            .failure = failure,
        };
    }

    pub fn get(handle: *const anyopaque) *Context {
        return @import("../../cli/sources/effects.zig").state(Context, handle);
    }

    pub fn fail(self: *const Context, err: anyerror) Error {
        self.failure.* = err;

        return error.InstallHostFailure;
    }
    pub fn physicalPath(self: *const Context, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
    }

    pub fn fetch(self: *const Context, release: pkgs.Index.Release, base: []const u8) ![]const u8 {
        return @import("package_store").prepare(self.io, self.allocator, release, base, self.cache, self.options.offline);
    }
};

pub fn currentWorkspaceMatches(handle: *const anyopaque) Error!bool {
    const self = Context.get(handle);
    const current = workspace.load(self.io, self.allocator, self.options.path) catch |err| return self.fail(err);

    return current.diagnostic == null and model.matchesWorkspace(self.lock.?.lock, current.packages);
}

pub fn renderInstallation(handle: *const anyopaque, paths: []const []const u8) Error!*const Rendered {
    const self = Context.get(handle);
    const input = self.lock.?;
    const publication = files.render(self.allocator, .{ .lock = input.lock, .paths = paths, .source = input.source }) catch |err| return self.fail(err);
    const digest = self.allocator.dupe(u8, &publication.digest) catch |err| return self.fail(err);
    const view = self.allocator.create(Rendered) catch |err| return self.fail(err);

    view.* = .{ .lock = publication.lock, .mapping = publication.mapping, .digest = digest };

    return view;
}
