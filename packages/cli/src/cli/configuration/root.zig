const std = @import("std");
const Compile = @import("../compile.zig");
const Options = @import("../options.zig");
const pkgs = @import("pkgs");
const yaml = @import("yaml.zig");
const Error = error{ OutOfMemory, Canceled };
const Content = @import("cli_abi").layouts.@"zig:lint_workflow_host".ConfigurationContent;
const Layout = @import("cli_abi").native.@"zig:lint_workflow_host".Layout;

pub fn toLayout(kind: ?Options.ConfigKind) Layout {
    return switch (kind orelse return .Unknown) {
        .manifest => .Manifest,
        .index => .Index,
        .lock => .Lock,
    };
}

pub fn run(context: Compile.Context) !Compile.Status {
    return execute(context) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: configuration: {s}\n", .{ context.options.input, @errorName(err) });

        return .failed;
    };
}

fn execute(context: Compile.Context) !Compile.Status {
    var arena = std.heap.ArenaAllocator.init(context.allocator);

    defer arena.deinit();

    const result = try @import("cli_source").configuration_workflow.executeIn(arena.allocator(), &.{
        .path = context.options.input,
        .input_path = context.options.input,
        .explicit_kind = toLayout(context.options.config_kind),
        .linting = context.options.linting,
        .check = context.options.check,
        .write = context.options.write,
    }, context.io);

    return report(context, result);
}

pub fn report(context: Compile.Context, result: anytype) !Compile.Status {
    if (result.error_name) |name| {
        try context.stderr.print("{s}: configuration: {s}\n", .{ context.options.input, name });

        return .failed;
    }

    if (result.diagnostic) |diagnostic| try context.stderr.writeAll(diagnostic);
    if (result.output) |output| try context.stdout.writeAll(output);

    return if (result.valid) .success else .failed;
}

fn errorName(err: anyerror) Error![]const u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => @errorName(err),
    };
}

fn view(allocator: std.mem.Allocator, content: struct {
    bytes: @FieldType(Content, "bytes") = null,
    diagnostic: @FieldType(Content, "diagnostic") = null,
    error_name: @FieldType(Content, "error_name") = null,
}) Error!*const Content {
    const result = try allocator.create(Content);

    result.* = .{
        .bytes = content.bytes,
        .diagnostic = content.diagnostic,
        .error_name = content.error_name,
    };

    return result;
}

pub fn readConfiguration(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: u64) Error!*const Content {
    const input = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(@intCast(limit))) catch |err| return view(allocator, .{ .error_name = try errorName(err) });

    return view(allocator, .{ .bytes = input });
}

pub fn formatConfigurationManifest(allocator: std.mem.Allocator, input: []const u8, path: []const u8) Error!*const Content {
    var diagnostics: std.Io.Writer.Allocating = .init(allocator);

    defer diagnostics.deinit();

    const formatted = yaml.format(allocator, input, path, &diagnostics.writer) catch |err| return view(allocator, .{ .error_name = try errorName(err) });

    return if (formatted) |result|
        view(allocator, .{ .bytes = result.bytes })
    else
        view(allocator, .{ .diagnostic = try diagnostics.toOwnedSlice() });
}

pub fn checkConfigurationJson(allocator: std.mem.Allocator, input: []const u8, lock: bool) Error!?[]const u8 {
    if (lock) {
        const checked = pkgs.Lock.parse(allocator, input) catch |err| return try errorName(err);

        checked.deinit();
    } else {
        const checked = pkgs.Index.parse(allocator, input) catch |err| return try errorName(err);

        checked.deinit();
    }

    return null;
}

pub fn formatConfigurationIndex(allocator: std.mem.Allocator, input: []const u8) Error!*const Content {
    const result = @import("lint").configuration.json.format(allocator, input) catch |err| return view(allocator, .{ .error_name = try errorName(err) });

    return view(allocator, .{ .bytes = result });
}
