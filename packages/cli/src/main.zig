const std = @import("std");
pub const native_lookup = @import("zx").native_lookup;

pub const resolveNative = native_lookup.Resolver(&.{
    @This(),
    @import("package/graph/host.zig"),
    @import("package/graph/installed/storage.zig"),
    @import("package/graph/workspace/storage.zig"),
    @import("package/install/fresh/archive_io.zig"),
    @import("package/install/fresh/storage.zig"),
    @import("package/install/host.zig"),
    @import("package/install/locked/storage.zig"),
    @import("cli/library/publish.zig"),
    @import("cli/library/stage/output.zig"),
    @import("cli/library/resources.zig"),
    @import("cli/library/build.zig"),
    @import("cli/library/analysis/rows.zig"),
    @import("cli/library/link/inputs.zig"),
    @import("cli/library/verify.zig"),
    @import("cli/sources/discovery/host.zig"),
    @import("cli/sources/templates.zig"),
    @import("package/workspace.zig"),
    @import("package/discover.zig"),
    @import("package/source.zig"),
    @import("package/project.zig"),
    @import("package/project/scope.zig"),
    @import("cli/project/scopes/host.zig"),
    @import("cli/abi.zig"),
    @import("cli/rx/collection/state.zig"),
    @import("cli/rx/collection/files.zig"),
    @import("cli/rx/collection/documents.zig"),
    @import("cli/rx/preparation/project.zig"),
    @import("cli/rx/preparation/references.zig"),
    @import("cli/rx/type_sources.zig"),
    @import("cli/rx/load.zig"),
    @import("cli/rx/store_types.zig"),
    @import("cli/rx/function.zig"),
    @import("cli/lint.zig"),
    @import("cli/lint/source.zig"),
    @import("cli/lint/semantic.zig"),
    @import("cli/lint/rx.zig"),
    @import("cli/lint/workspace.zig"),
    @import("cli/lint/sources.zig"),
    @import("cli/configuration/root.zig"),
    @import("cli/rx/compile.zig"),
    @import("cli/rx/gateway/analyze.zig"),
    @import("cli/rx/gateway/compile.zig"),
    @import("cli/build/native.zig"),
    @import("cli/build/dependencies/history.zig"),
    @import("cli/build/prepare.zig"),
    @import("cli/build/arguments.zig"),
    @import("cli/build/modules.zig"),
    @import("cli/compilation/state.zig"),
    @import("cli/compilation/emit.zig"),
    @import("cli/cache.zig"),
    @import("cli/fpga.zig"),
    watch.driver,
    watch.driver.build,
    watch.driver.wait,
    watch.driver.process,
}).resolve;

pub const watch = @import("cli/watch.zig");
pub const toolchain = @import("cli/toolchain.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.initStreaming(.stdout(), init.io, &stdout_buffer);
    var stderr_file = std.Io.File.Writer.initStreaming(.stderr(), init.io, &stderr_buffer);
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const request = try @import("cli_source").command_request.executeValue(allocator, args[1..]);
    const check = @import("cli/rx/check.zig");

    const success = switch (request.action) {
        .Compilation => try compile(init, args[1..], stdout, stderr),
        .Help => help: {
            try usage(stdout);

            break :help true;
        },
        .RxEntry => try check.entry(init.io, allocator, init.gpa, request.path.?, request.project, stderr),
        .RxSources => try check.sources(init.io, allocator, args[2..], stderr),
        .RxEntryUsage => try invalid(stderr, "check-rx --entry requires one RX file and optional --project pkg.yaml\n"),
        .RxSourcesUsage => try invalid(stderr, "check-rx requires the complete set of ordinary RX module paths\n"),
        else => try @import("package/command.zig").run(init, request, args[2..], stdout, stderr),
    };

    if (!success) {
        try stderr.flush();

        std.process.exit(1);
    }
}

fn compile(init: std.process.Init, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    const options = @import("cli/options.zig").parse(args) catch {
        try usage(stderr);

        return false;
    };

    if (options.run) {
        try @import("cli/watch/interrupt.zig").run(init.io, std.heap.page_allocator, options, init.environ_map, stdout, stderr);
    } else if (options.watch) {
        try @import("cli/watch.zig").run(init.io, std.heap.page_allocator, options, init.environ_map, stdout, stderr);
    } else {
        const result = try @import("cli/compile.zig").run(.{ .io = init.io, .allocator = init.arena.allocator(), .backing = init.gpa, .concurrent_analysis = true, .options = options, .environment = init.environ_map, .stdout = stdout, .stderr = stderr });

        return result == .success;
    }

    return true;
}

fn invalid(writer: *std.Io.Writer, message: []const u8) !bool {
    try writer.writeAll(message);

    return false;
}

fn usage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(@import("package/command.zig").manifest_usage);
    try writer.writeAll(@import("package/init.zig").usage);
    try writer.writeAll(@import("package/install.zig").usage);
    try writer.writeAll("zxc lint <source.zx|source.rx|pkg.yaml|pkg.lock.json> [--kind manifest|index|lock]\n");
    try writer.writeAll("zxc lint <source.zx|source.rx|pkg.yaml> --semantic [--project pkg.yaml]\n");
    try writer.writeAll("zxc lint pkg.yaml --workspace\n");
    try writer.writeAll("Options for compile/build/verify/fpga: --no-cache --cache-stats\n");
    try writer.writeAll("build --watch --run [-- application arguments]: restart native app after successful builds; stdin closed, stdout/stderr inherited\n");
    try writer.writeAll("zxc verify <pkg.yaml> [--solver z3] [--out query.smt2]: verify all declared public modules\n");
    try writer.writeAll("RX Call/Loop/Task/If/Switch and pure Parallel Call/Task branches: zxc <module.rx> [--out output.zig] or zxc build <module.rx> --out program; app build options apply; lib publishing uses build pkg.yaml --mode lib --out directory or a source entry\n");
    try writer.writeAll(@import("package/index.zig").usage);
    try writer.writeAll("zxc <source.zx> [--project pkg.yaml] [--out output.zig] [--solver z3]\nzxc build <source.zx> --out program [--mode app|lib] [--host process|node] [--node-lib file] [--result json|discard] [--watch [--run]] [--project pkg.yaml] [--asm program.s] [--target triple] [--cpu features] [--optimize mode] [--solver z3]\nzxc fpga <source.zx> --out kernel.sv [--project pkg.yaml] [--solver z3] [--clocked]\nzxc verify <source.zx> [--project pkg.yaml] [--solver z3] [--out query.smt2]\nzxc fmt <source.zx|source.rx|pkg.yaml> [--check | --write] [--kind manifest|index]\nzxc check-rx <module.rx> [module.rx ...]\nzxc check-rx --entry <module.rx|gateway.gateway.rx|state.store.rx> [--project pkg.yaml]\n");
}
