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
    var state = try host.State.init(io, allocator, options, environment);

    defer state.deinit();

    const result = @import("cli_source").workflow.executeValue(allocator, &.{
        .host = @ptrCast(&state),
        .members = state.members.len,
        .maximum_edges = pkgs.Lock.maximum_dependencies,
        .locked_rows = if (state.previous) |previous| previous.lock.packages.len else 0,
        .has_lock = state.previous != null,
        .reuse = state.reuse,
        .frozen = options.frozen,
    }) catch |err| switch (err) {
        error.InstallHostFailure => return state.failure.?,
        else => |failure| return failure,
    };

    return switch (result) {
        .Installed => state.prepared.lock.packages.len,
        .LockFileMissing => error.LockFileMissing,
        .LockFileOutdated => error.LockFileOutdated,
        .WorkspaceChangedDuringInstall => error.WorkspaceChangedDuringInstall,
        .LockChangedDuringInstall => error.LockChangedDuringInstall,
        .PackageInstallationTooLarge => error.PackageInstallationTooLarge,
    };
}
