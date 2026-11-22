const std = @import("std");
const rx = @import("rx");
const rx_analysis = @import("rx_analysis");
const f = @import("fixture.zig");
const compiler = f.compiler;

pub fn analyze(allocator: std.mem.Allocator, distinct: bool, zx_consumer: bool) !compiler.AnalysisResult {
    var original = try f.library(std.testing.allocator, .single);

    defer original.deinit();

    const bytes = try compiler.library.codec.encode(std.testing.allocator, &original);

    defer std.testing.allocator.free(bytes);

    var library = try compiler.library.codec.decode(std.testing.allocator, bytes);

    defer library.deinit();
    @memset(bytes, 0);

    const first = compiler.project.compiled.Library{ .instance = "counter@1", .artifact = "library.zxcir", .program = library.program, .exports = library.exports, .nominal_types = library.nominal_types, .store_initializers = library.store_initializers };
    var second = first;

    second.instance = "counter@2";

    const options: compiler.project.Options = .{
        .entry = if (zx_consumer) "main.zx" else "main.rx",
        .root_dir = "/consumer",
        .packages = &.{
            .{ .specifier = "first", .compiled = .{ .instance = first.instance, .artifact = first.artifact, .name = "left" } },
            .{ .specifier = "second", .compiled = .{ .instance = if (distinct) second.instance else first.instance, .artifact = first.artifact, .name = "left" } },
        },
        .compiled_libraries = if (distinct) &.{ first, second } else &.{first},
    };

    if (zx_consumer) {
        const source =
            \\import read from "first"
            \\export type Input = void
            \\export type Output = u64
            \\export default function (in: Input): Output { return read(in) }
        ;

        return compiler.project.analyze(allocator, &.{.{ .path = options.entry, .source = source }}, options);
    }

    const source =
        \\<Module>
        \\    <Call module="first" in={$in} />
        \\    <Call module="second" in={$in} />
        \\    <Return value={$ctx.second} />
        \\</Module>
    ;
    var parsed = try rx.parseXml(allocator, source);

    defer parsed.deinit();

    try std.testing.expect(parsed.value == .node);

    var inferred = try rx_analysis.project.infer(allocator, .{
        .entry = options.entry,
        .modules = &.{.{ .path = options.entry, .node = parsed.value.node }},
        .sources = &.{},
        .project = options,
    });

    errdefer inferred.deinit();

    try std.testing.expect(inferred.value == .contract);

    const contract = inferred.value.contract;

    return .{
        .arena = inferred.arena,
        .value = .{ .ir = contract.program },
        .nominal_types = contract.nominal_types,
        .store_initializers = contract.store_initializers,
    };
}
