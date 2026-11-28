const std = @import("std");
const pkgs = @import("pkgs");
const memory = @import("zx").memory;
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
    var session = try host.Context.init(io, allocator, options, environment, &failure);
    const previous = try files.load(io, allocator, session.root, null);

    if (previous) |lock| session.lock = .{ .lock = lock.lock, .source = lock.source };

    const reuse = if (previous) |lock| @import("install/model.zig").matchesWorkspace(lock.lock, session.members) else false;
    const packages: []const pkgs.Lock.Package = if (reuse) session.lock.?.lock.packages else &.{};
    const locked_workspace = try allocator.alloc(?[]const u8, packages.len);

    for (locked_workspace, packages) |*path, package| {
        path.* = if (package.source == .workspace) package.source.workspace else null;
    }

    var sample: pkgs.Lock.Package = undefined;
    sample.source = .{ .archive = undefined };

    const names = memory.borrowTextColumn("name", packages);
    const versions = memory.borrowTextColumn("version", packages);
    const sources = memory.borrowProjectedText(packages, &sample, &sample.source.archive.archive);
    const digests = memory.borrowProjectedText(packages, &sample, &sample.source.archive.sha256);
    const reference = &session;

    const result = @import("cli_source").workflow.executeIn(allocator, &.{
        .session = @ptrCast(&reference),
        .members = session.members.len,
        .maximum_edges = pkgs.Lock.maximum_dependencies,
        .maximum_bytes = files.maximum_bytes,
        .root = session.root,
        .has_lock = previous != null,
        .locked_workspace = locked_workspace,
        .locked_archives = &.{
            .names = @ptrCast(&names),
            .versions = @ptrCast(&versions),
            .sources = @ptrCast(&sources),
            .digests = @ptrCast(&digests),
        },
        .reuse = reuse,
        .frozen = options.frozen,
    }, io) catch |err| switch (err) {
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
