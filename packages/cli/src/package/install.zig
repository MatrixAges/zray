const std = @import("std");
const pkgs = @import("pkgs");
const Options = @import("install/options.zig");
pub const usage = Options.usage;

pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, environment: *const std.process.Environ.Map, output: *std.Io.Writer, errors: *std.Io.Writer) !bool {
    const options = Options.parse(args) catch {
        try errors.writeAll(usage);

        return false;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const count = install(io, arena.allocator(), options, environment) catch |err| {
        if (err == error.OutOfMemory) return err;

        try errors.print("{s}: install: {s}\n", .{ options.path, @errorName(err) });

        return false;
    };

    try output.print("Installed {d} packages; pkg.lock.json is up to date.\n", .{count});

    return true;
}

fn install(io: std.Io, allocator: std.mem.Allocator, options: Options, environment: *const std.process.Environ.Map) !usize {
    const host = @import("install/host.zig");
    const files = @import("install/files.zig");
    var failure: ?anyerror = null;
    const session = try host.Context.init(io, allocator, options, environment, &failure);
    const previous = try files.load(io, allocator, session.root, null);
    const data: host.LockData = if (previous) |lock| .{ .lock = lock.lock, .source = lock.source } else undefined;
    const reuse = if (previous) |lock| @import("install/model.zig").matchesWorkspace(lock.lock, session.members) else false;
    const locked_workspace: []?[]const u8 = if (reuse) try allocator.alloc(?[]const u8, data.lock.packages.len) else &.{};

    if (reuse) {
        for (locked_workspace, data.lock.packages) |*path, package| {
            path.* = if (package.source == .workspace) package.source.workspace else null;
        }
    }

    const result = @import("cli_source").workflow.executeIn(allocator, &.{
        .session = @ptrCast(&session),
        .members = session.members.len,
        .maximum_edges = pkgs.Lock.maximum_dependencies,
        .maximum_bytes = files.maximum_bytes,
        .root = session.root,
        .previous = if (previous != null) @ptrCast(&data) else null,
        .locked_workspace = locked_workspace,
        .reuse = reuse,
        .frozen = options.frozen,
    }) catch |err| switch (err) {
        error.InstallHostFailure => return failure.?,
        else => return err,
    };

    return switch (result.status) {
        .Installed => @intCast(result.count.?),
        .LockFileMissing => error.LockFileMissing,
        .LockFileOutdated => error.LockFileOutdated,
        .WorkspaceChangedDuringInstall => error.WorkspaceChangedDuringInstall,
        .LockChangedDuringInstall => error.LockChangedDuringInstall,
        .PackageInstallationTooLarge => error.PackageInstallationTooLarge,
    };
}
