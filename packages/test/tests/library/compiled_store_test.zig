const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const rx_analysis = @import("rx_analysis");
const fixture = @import("store_fixture.zig");

fn analyze(zx_consumer: bool, distinct: bool) !compiler.AnalysisResult {
    var original = try fixture.link(std.testing.allocator, "state.store.rx", "u64", false);

    defer original.deinit();

    const bytes = try compiler.library.codec.encode(std.testing.allocator, &original);

    defer std.testing.allocator.free(bytes);

    var library = try compiler.library.codec.decode(std.testing.allocator, bytes);

    defer library.deinit();
    @memset(bytes, 0);

    const first = compiler.project.compiled.Library{ .instance = "sample@1", .artifact = "sample.zxlib", .program = library.program, .exports = library.exports, .nominal_types = library.nominal_types };
    var second = first;
    second.instance = "sample@2";

    const options: compiler.project.Options = .{
        .entry = if (zx_consumer) "consumer.zx" else "consumer.rx",
        .root_dir = "/consumer",
        .packages = &.{
            .{ .specifier = "left", .compiled = .{ .instance = first.instance, .artifact = first.artifact, .name = "left" } },
            .{ .specifier = "right", .compiled = .{ .instance = if (distinct) second.instance else first.instance, .artifact = first.artifact, .name = "right" } },
        },
        .compiled_libraries = if (distinct) &.{ first, second } else &.{first},
    };

    if (zx_consumer) {
        const source = "import run from \"left\"\nexport type Input = void\nexport type Output = u64\nexport default function (in: Input): Output { return run(in) }\n";

        return compiler.project.analyze(std.testing.allocator, &.{.{ .path = options.entry, .source = source }}, options);
    }

    const source = "<Module><Call module='left' in={$in}/><Call module='right' in={$in}/><Return value={$ctx.right}/></Module>";
    var parsed = try rx.parseXml(std.testing.allocator, source);

    defer parsed.deinit();

    try std.testing.expect(parsed.value == .node);

    var inferred = try rx_analysis.project.infer(std.testing.allocator, .{
        .entry = options.entry,
        .modules = &.{.{ .path = options.entry, .node = parsed.value.node }},
        .sources = &.{},
        .project = options,
    });

    errdefer inferred.deinit();

    if (inferred.value == .diagnostic) {
        std.debug.print("compiled Store import: {s}: {s}\n", .{ inferred.value.diagnostic.code, inferred.value.diagnostic.message });
    }

    try std.testing.expect(inferred.value == .contract);

    const contract = inferred.value.contract;

    return .{ .arena = inferred.arena, .value = .{ .ir = contract.program }, .nominal_types = contract.nominal_types, .store_initializers = contract.store_initializers };
}

test "compiled RX calls share one read-only Store slot from the same instance" {
    var result = try analyze(false, false);

    defer result.deinit();

    try std.testing.expect(result.value == .ir);
    try std.testing.expectEqual(@as(usize, 1), result.value.ir.stores.count());

    const slot = result.value.ir.stores.at(0);

    try std.testing.expect(slot.readable and !slot.writable);
    try std.testing.expect(try compiler.validateIr(std.testing.allocator, result.value.ir) == null);

    var bundle = try compiler.zig.emitModules(std.testing.allocator, &result);

    defer bundle.deinit();
}

test "compiled Store instances keep valid distinct state paths" {
    var result = try analyze(false, true);

    defer result.deinit();

    try std.testing.expect(result.value == .ir);
    try std.testing.expect(try compiler.validateIr(std.testing.allocator, result.value.ir) == null);

    var paths: std.StringHashMapUnmanaged(void) = .empty;

    defer paths.deinit(std.testing.allocator);

    for (0..result.value.ir.functions.count()) |function_row| {
        const function = result.value.ir.functions.at(function_row);

        for (0..function.stores.count()) |store_index| {
            const slot = function.stores.at(store_index);

            try std.testing.expect(std.mem.startsWith(u8, slot.path, "store."));
            try paths.put(std.testing.allocator, slot.path, {});
        }
    }

    try std.testing.expectEqual(@as(usize, 2), paths.count());
}

test "ordinary ZX rejects imports of compiled RX workflows with Store" {
    var result = try analyze(true, false);

    defer result.deinit();

    try std.testing.expect(result.value == .diagnostic);
    try std.testing.expectEqual(.module, result.value.diagnostic.code);
    try std.testing.expect(std.mem.startsWith(u8, result.value.diagnostic.message, "ZX cannot import RX modules"));
    try std.testing.expectEqual(@as(?usize, 0), result.value.diagnostic.source_index);
}
