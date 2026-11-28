const std = @import("std");
const Compile = @import("compile.zig");

pub fn run(context: Compile.Context) !Compile.Status {
    const action = try @import("cli_source").lint_command.executeIn(context.allocator, &.{
        .input_path = context.options.input,
        .explicit_kind = @import("configuration/root.zig").toLayout(context.options.config_kind),
        .workspace = context.options.workspace_lint,
        .semantic = context.options.semantic_lint,
    });

    return switch (action) {
        .Workspace => @import("lint/workspace.zig").run(context),
        .Semantic => @import("lint/semantic.zig").run(context),
        .Configuration => @import("configuration/root.zig").run(context),
        .InvalidInput => invalid: {
            try context.stderr.writeAll("lint requires ZX, RX, pkg.yaml, pkg.lock.json or an explicit --kind selection\n");

            break :invalid .failed;
        },
        .Source => lintSourceFile(context),
    };
}

pub const checkSource = @import("lint/source.zig").check;

fn lintSourceFile(context: Compile.Context) !Compile.Status {
    const path = context.options.input;

    const source = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: {s}\n", .{ path, @errorName(err) });

        return .failed;
    };

    defer context.allocator.free(source);

    return checkSource(context, source);
}
