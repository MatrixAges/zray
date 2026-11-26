const std = @import("std");
const CompilationRequest = std.meta.Child(@import("cli_source").compile_command.Input);
const Settings = std.meta.Child(@FieldType(CompilationRequest, "settings"));
pub const ConfigKind = enum { manifest, index, lock };

pub const Options = struct {
    input: []const u8,
    output: ?[]const u8 = null,
    project: ?[]const u8 = null,
    formatting: bool = false,
    linting: bool = false,
    semantic_lint: bool = false,
    workspace_lint: bool = false,
    config_kind: ?ConfigKind = null,
    max_lines: ?usize = null,
    check: bool = false,
    write: bool = false,
    native: bool = false,
    mode: enum { app, lib } = .app,
    host: enum { process, node } = .process,
    node_library: ?[]const u8 = null,
    result: enum { json, discard } = .json,
    verifying: bool = false,
    fpga: bool = false,
    clocked: bool = false,
    assembly: ?[]const u8 = null,
    target: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    optimize: std.builtin.OptimizeMode = .safe,
    solver: ?[]const u8 = null,
    cache: bool = true,
    cache_stats: bool = false,
    watch: bool = false,
    run: bool = false,
    run_args: []const []const u8 = &.{},
    pub fn executionSettings(self: *const Options) Settings {
        return .{
            .formatting = self.formatting,
            .linting = self.linting,
            .library = self.mode == .lib,
            .verifying = self.verifying,
            .fpga = self.fpga,
            .native = self.native,
            .cache = self.cache,
            .cache_stats = self.cache_stats,
            .json_result = self.result == .json,
            .check = self.check,
            .write = self.write,
            .output = self.output,
        };
    }
};

pub fn parse(args: []const []const u8) error{InvalidArguments}!Options {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const state = @import("cli_source").arguments.executeValue(empty.allocator(), &.{ .args = args, .maximum = std.math.maxInt(usize) }) catch unreachable;

    if (!state.valid) return error.InvalidArguments;

    var options = Options{
        .input = args[@intCast(state.input)],
        .output = argument(args, state.output),
        .project = argument(args, state.project),
        .formatting = state.command == .Format,
        .linting = state.command == .Lint,
        .semantic_lint = state.semantic,
        .workspace_lint = state.workspace,
        .max_lines = if (state.max_lines) |n| @intCast(n) else null,
        .check = state.check,
        .write = state.write,
        .native = state.command == .Build,
        .node_library = argument(args, state.node_library),
        .verifying = state.command == .Verify,
        .fpga = state.command == .Hardware,
        .clocked = state.clocked,
        .assembly = argument(args, state.assembly),
        .target = argument(args, state.target),
        .cpu = argument(args, state.cpu),
        .solver = argument(args, state.solver),
        .cache = !state.no_cache,
        .cache_stats = state.cache_stats,
        .watch = state.watch,
        .run = state.run,
        .run_args = if (state.tail == 0) &.{} else args[@intCast(state.tail)..],
    };

    if (argument(args, state.kind)) |value| options.config_kind = std.meta.stringToEnum(ConfigKind, value) orelse return error.InvalidArguments;
    if (argument(args, state.mode)) |value| options.mode = std.meta.stringToEnum(@TypeOf(options.mode), value) orelse return error.InvalidArguments;
    if (argument(args, state.host)) |value| options.host = std.meta.stringToEnum(@TypeOf(options.host), value) orelse return error.InvalidArguments;
    if (argument(args, state.result)) |value| options.result = std.meta.stringToEnum(@TypeOf(options.result), value) orelse return error.InvalidArguments;
    if (argument(args, state.optimize)) |value| options.optimize = std.builtin.OptimizeMode.fromString(value) orelse return error.InvalidArguments;

    return options;
}

fn argument(args: []const []const u8, index: u64) ?[]const u8 {
    return if (index == 0) null else args[@intCast(index)];
}
