const std = @import("std");
const api = @import("zxc_abi").native.@"std:child_process";
const Arguments = @import("options.zig");
pub const TerminationKind = api.TerminationKind;
pub const EnvironmentEntry = api.EnvironmentEntry;
pub const Options = api.Options;
pub const InputOptions = api.InputOptions;
pub const Result = api.Result;

pub fn spawnSync(allocator: std.mem.Allocator, io: std.Io, input: Options) !Result {
    return execute(allocator, io, input, null);
}

pub fn spawnSyncWithInput(allocator: std.mem.Allocator, io: std.Io, input: InputOptions) !Result {
    return execute(allocator, io, input.options, input.input);
}

fn execute(allocator: std.mem.Allocator, io: std.Io, input: Options, bytes: ?[]const u8) !Result {
    var arguments = try Arguments.init(allocator, input);

    defer arguments.deinit();

    const options: std.process.RunOptions = .{
        .argv = arguments.argv,
        .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = if (arguments.environment) |*environment| environment else null,
        .stdout_limit = .limited64(input.max_stdout_bytes),
        .stderr_limit = .limited64(input.max_stderr_bytes),
    };

    return capture(allocator, io, options, bytes);
}

pub fn spawnSyncBytes(allocator: std.mem.Allocator, io: std.Io, input: api.ByteArguments) !Result {
    if (input.argv.len == 0) return error.EmptyCommand;

    for (input.argv) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidProcessArgument;
    }

    return capture(allocator, io, .{
        .argv = input.argv,
        .stdout_limit = .limited64(input.max_stdout_bytes),
        .stderr_limit = .limited64(input.max_stderr_bytes),
    }, null);
}

fn capture(allocator: std.mem.Allocator, io: std.Io, options: std.process.RunOptions, bytes: ?[]const u8) !Result {
    const result = try allocator.create(api.spawnSync.OutputValue);

    errdefer allocator.destroy(result);

    const captured = if (bytes) |data|
        try @import("run.zig").run(allocator, io, options, data)
    else
        try std.process.run(allocator, io, options);

    errdefer allocator.free(captured.stdout);
    errdefer allocator.free(captured.stderr);

    if (options.stdout_limit.toInt()) |limit| {
        if (captured.stdout.len > limit) return error.StreamTooLong;
    }

    if (options.stderr_limit.toInt()) |limit| {
        if (captured.stderr.len > limit) return error.StreamTooLong;
    }

    result.* = .{
        .stdout = captured.stdout,
        .stderr = captured.stderr,
        .kind = switch (captured.term) {
            .exited => .Exited,
            .signal => .Signal,
            .stopped => .Stopped,
            .unknown => .Unknown,
        },
        .code = switch (captured.term) {
            .exited => |code| code,
            .signal, .stopped => |signal| @backingInt(signal),
            .unknown => |code| code,
        },
    };

    return result;
}
