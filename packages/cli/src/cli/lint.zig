const std = @import("std");
const Compile = @import("compile.zig");
const effects = @import("sources/effects.zig");
const Error = effects.Error;

const Command = struct {
    context: *const Compile.Context,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *Command {
        return effects.state(Command, handle);
    }
};

pub fn run(context: Compile.Context) !Compile.Status {
    var command: Command = .{ .context = &context };
    const reference = &command;

    const valid = @import("cli_source").lint_command.executeIn(context.allocator, &.{
        .host = @ptrCast(&reference),
        .input_path = context.options.input,
        .explicit_kind = @import("configuration/root.zig").toLayout(context.options.config_kind),
        .workspace = context.options.workspace_lint,
        .semantic = context.options.semantic_lint,
    }) catch |err| return command.failure.unwrap(err);

    return if (valid) .success else .failed;
}

pub const checkSource = @import("lint/source.zig").check;

pub fn lintConfiguration(handle: *const anyopaque) Error!bool {
    const self = Command.get(handle);
    const status = @import("configuration/root.zig").run(self.context.*) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn lintSemantic(handle: *const anyopaque) Error!bool {
    const self = Command.get(handle);
    const status = @import("lint/semantic.zig").run(self.context.*) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn lintWorkspace(handle: *const anyopaque) Error!bool {
    const self = Command.get(handle);
    const status = @import("lint/workspace.zig").run(self.context.*) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn reportLintInput(handle: *const anyopaque) Error!void {
    const self = Command.get(handle);

    self.context.stderr.writeAll("lint requires ZX, RX, pkg.yaml, pkg.lock.json or an explicit --kind selection\n") catch |err| return self.failure.save(err);
}

pub fn lintSourceFile(handle: *const anyopaque) Error!bool {
    const self = Command.get(handle);
    const context = self.context.*;
    const path = context.options.input;

    const source = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.failure.save(err);

        context.stderr.print("{s}: {s}\n", .{ path, @errorName(err) }) catch |issue| return self.failure.save(issue);

        return false;
    };

    defer context.allocator.free(source);

    const status = checkSource(context, source) catch |err| return self.failure.save(err);

    return status == .success;
}
