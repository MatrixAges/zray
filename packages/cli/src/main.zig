const std = @import("std");
pub const watch = @import("cli/watch.zig");
pub const package_graph = @import("package/graph/host.zig");
pub const toolchain = @import("cli/toolchain.zig");
pub const installation = @import("package/install/host.zig");
pub const library_stage = @import("cli/library/publish.zig");

pub const package_workspace = struct {
    pub const collection = @import("package/workspace.zig");
    pub const discovery = @import("package/discover.zig");
    pub const source = @import("package/source.zig");
    pub const project = @import("package/project.zig");
};

pub const library_workflow = struct {
    pub const build = @import("cli/library/build.zig");
    pub const analysis = @import("cli/library/analysis/rows.zig");
    pub const link = @import("cli/library/link/inputs.zig");
    pub const proof = @import("cli/library/verify.zig");
};

pub const source_loader = struct {
    pub const discovery = @import("cli/sources/discovery/host.zig");
    pub const templates = @import("cli/sources/templates.zig");
};

pub const rx_collection = struct {
    pub const state = @import("cli/rx/collection/state.zig");
    pub const files = @import("cli/rx/collection/files.zig");
    pub const documents = @import("cli/rx/collection/documents.zig");
};

pub const rx_preparation = struct {
    pub const project = @import("cli/rx/preparation/project.zig");
    pub const references = @import("cli/rx/preparation/references.zig");
    pub const types = @import("cli/rx/type_sources.zig");
};

pub const rx_checking = struct {
    pub const project = @import("cli/rx/load.zig");
    pub const store = @import("cli/rx/store_types.zig");
    pub const function = @import("cli/rx/function.zig");
};

pub const lint_workflow = struct {
    pub const command = @import("cli/lint.zig");
    pub const source = @import("cli/lint/source.zig");
    pub const semantic = @import("cli/lint/semantic.zig");
    pub const special = @import("cli/lint/rx.zig");
    pub const workspace = @import("cli/lint/workspace.zig");
    pub const reachable = @import("cli/lint/sources.zig");
    pub const configuration = @import("cli/configuration/root.zig");
};

pub const rx_execution = struct {
    pub const application = @import("cli/rx/compile.zig");
    pub const analysis = @import("cli/rx/gateway/analyze.zig");
    pub const gateway = @import("cli/rx/gateway/compile.zig");
    pub const backend = @import("cli/build/native.zig");
    pub const compilation = @import("cli/compilation/state.zig");
    pub const emit = @import("cli/compilation/emit.zig");
    pub const cache = @import("cli/cache.zig");
    pub const fpga = @import("cli/fpga.zig");
};

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

    if (args.len > 1 and std.mem.eql(u8, args[1], "pkg")) {
        if (!try @import("package/command.zig").run(init.io, allocator, args[2..], init.environ_map, stdout, stderr)) {
            try stderr.flush();

            std.process.exit(1);
        }

        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "check-rx")) {
        if (!try @import("cli/rx/check.zig").run(init.io, allocator, init.gpa, args[2..], stderr)) {
            try stderr.flush();

            std.process.exit(1);
        }

        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try usage(stdout);

        return;
    }

    const options = @import("cli/options.zig").parse(args[1..]) catch {
        try usage(stderr);
        try stderr.flush();

        std.process.exit(1);
    };

    if (options.run) {
        try @import("cli/watch/interrupt.zig").run(init.io, std.heap.page_allocator, options, init.environ_map, stdout, stderr);
    } else if (options.watch) {
        try @import("cli/watch.zig").run(init.io, std.heap.page_allocator, options, init.environ_map, stdout, stderr);
    } else if (try @import("cli/compile.zig").run(.{ .io = init.io, .allocator = allocator, .backing = init.gpa, .concurrent_analysis = true, .options = options, .environment = init.environ_map, .stdout = stdout, .stderr = stderr }) != .success) {
        try stderr.flush();

        std.process.exit(1);
    }
}

fn usage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("zxc pkg inspect|workspace|graph [pkg.yaml]\n");
    try writer.writeAll(@import("package/init.zig").usage);
    try writer.writeAll(@import("package/install.zig").usage);
    try writer.writeAll("zxc lint <source.zx|source.rx|pkg.yaml|pkg.lock.json> [--kind manifest|index|lock]\n");
    try writer.writeAll("zxc lint <source.zx|source.rx|pkg.yaml> --semantic [--project pkg.yaml]\n");
    try writer.writeAll("zxc lint pkg.yaml --workspace\n");
    try writer.writeAll("Options for compile/build/verify/fpga: --no-cache --cache-stats\n");
    try writer.writeAll("build --watch --run [-- application arguments]: restart native app after successful builds; stdin closed, stdout/stderr inherited\n");
    try writer.writeAll("zxc verify <pkg.yaml> [--solver z3] [--out query.smt2]: verify all declared public modules\n");
    try writer.writeAll("RX Call/Loop/Task/If/Switch and pure Parallel Call/Task branches: zxc <module.rx> [--out output.zig] or zxc build <module.rx> --out program; app build options apply; lib publishing uses build pkg.yaml --mode lib --out directory or a source entry\n");
    try writer.writeAll("zxc pkg index [index.json]\nzxc pkg resolve <name> <range> [index.json]\n");
    try writer.writeAll("zxc <source.zx> [--project pkg.yaml] [--out output.zig] [--solver z3]\nzxc build <source.zx> --out program [--mode app|lib] [--host process|node] [--node-lib file] [--result json|discard] [--watch [--run]] [--project pkg.yaml] [--asm program.s] [--target triple] [--cpu features] [--optimize mode] [--solver z3]\nzxc fpga <source.zx> --out kernel.sv [--project pkg.yaml] [--solver z3] [--clocked]\nzxc verify <source.zx> [--project pkg.yaml] [--solver z3] [--out query.smt2]\nzxc fmt <source.zx|source.rx|pkg.yaml> [--check | --write] [--kind manifest|index]\nzxc check-rx <module.rx> [module.rx ...]\nzxc check-rx --entry <module.rx|gateway.gateway.rx|state.store.rx> [--project pkg.yaml]\n");
}
