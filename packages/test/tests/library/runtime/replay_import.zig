const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const rx_analysis = @import("rx_analysis");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 4) return error.ExpectedArtifactDirectoryAndOrder;

    var imported = block: {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], std.heap.page_allocator, .limited(16 * 1024 * 1024));

        defer std.heap.page_allocator.free(bytes);

        var library = try compiler.library.codec.decode(std.heap.page_allocator, bytes);

        defer library.deinit();
        @memset(bytes, 0);

        var analyses: std.ArrayList(compiler.AnalysisResult) = .empty;

        defer for (analyses.items) |*analysis| analysis.deinit();

        var inputs: std.ArrayList(compiler.library.Input) = .empty;

        try analyses.ensureTotalCapacity(allocator, library.exports.len);

        for (library.exports) |exported| {
            const is_rx = std.mem.endsWith(u8, exported.path, ".rx");
            const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ exported.name, if (is_rx) "rx" else "zx" });

            const options: compiler.project.Options = .{
                .entry = path,
                .root_dir = "/consumer",
                .packages = &.{.{ .specifier = "dependency", .compiled = .{ .instance = "workflow@1", .artifact = "library.zxlib", .name = exported.name } }},
                .compiled_libraries = &.{.{ .instance = "workflow@1", .artifact = "library.zxlib", .program = library.program, .exports = library.exports, .nominal_types = library.nominal_types }},
            };

            var analysis = if (is_rx) try analyzeRx(path, options) else try compiler.project.analyze(std.heap.page_allocator, &.{
                .{ .path = path, .source = "import run from \"dependency\"\nimport type { Input, Output } from \"dependency\"\nexport default function (in: Input): Output { return run(in) }\n" },
            }, options);

            errdefer analysis.deinit();

            if (analysis.value == .diagnostic) {
                std.debug.print("{s}: {s}\n", .{ exported.name, analysis.value.diagnostic.message });

                return error.InvalidConsumer;
            }

            analyses.appendAssumeCapacity(analysis);
        }

        for (library.exports, analyses.items) |exported, *analysis| {
            try inputs.append(allocator, .{ .name = exported.name, .analysis = analysis });
        }

        break :block try compiler.library.link(allocator, inputs.items);
    };

    defer imported.deinit();

    try @import("emit.zig").emit(init.io, allocator, &imported, args[2]);
}

fn analyzeRx(path: []const u8, options: compiler.project.Options) !compiler.AnalysisResult {
    const allocator = std.heap.page_allocator;
    var parsed = try rx.parseXml(allocator, "<Module><Call module='dependency' in={$in}/><Return value={$ctx.dependency}/></Module>");

    defer parsed.deinit();

    if (parsed.value != .node) return error.InvalidXml;

    var inferred = try rx_analysis.project.infer(allocator, .{
        .entry = path,
        .modules = &.{.{ .path = path, .node = parsed.value.node }},
        .sources = &.{},
        .project = options,
    });

    errdefer inferred.deinit();

    if (inferred.value == .diagnostic) {
        std.debug.print("{s}: {s}\n", .{ path, inferred.value.diagnostic.message });

        return error.InvalidConsumer;
    }

    const contract = inferred.value.contract;

    return .{ .arena = inferred.arena, .value = .{ .ir = contract.program }, .nominal_types = contract.nominal_types };
}
