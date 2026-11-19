const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const analysis = @import("rx_analysis");
const collection = @import("source_collection.zig");
const Kind = compiler.source_inputs.Kind;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 4) return error.OutputCountMismatch;

    return generate(init, args[1], args[2], args[3]);
}

pub fn generate(init: std.process.Init, source_root: []const u8, core_root: []const u8, output_path: []const u8) !void {
    const entry = "scan.rx";
    const allocator = init.arena.allocator();
    var documents: std.ArrayList(collection.Document) = .empty;

    try collection.collect(init.io, allocator, allocator, null, source_root, "", &documents);

    const packages = [_]compiler.project.Package{
        .{ .specifier = "core/const", .entry = "core/const.zx" },
        .{ .specifier = "core/ascii/const", .entry = "core/ascii/const.zx" },
    };

    for (packages) |package| {
        const relative = package.entry["core/".len..];
        const path = try std.fs.path.join(allocator, &.{ core_root, relative });
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .unlimited);

        try documents.append(allocator, .{ .path = package.entry, .text = source, .kind = @backingInt(Kind.ZX) });
    }

    const inputs = try collection.publish(allocator, allocator, documents.items, &.{}, false);
    var parsed = try rx.parseReachableModules(allocator, inputs.modules, entry);

    defer parsed.deinit();

    if (parsed.value == .diagnostic) {
        const issue = parsed.value.diagnostic;

        std.debug.print("{s}: {s}\n", .{ inputs.modules[issue.source_index].path, issue.issue.message });

        return error.InvalidLexerModule;
    }

    var analyzed = try analysis.project.infer(allocator, .{
        .entry = entry,
        .modules = parsed.selected,
        .sources = inputs.sources,
        .project = .{ .entry = "", .packages = &packages },
    });

    defer analyzed.deinit();

    if (analyzed.value == .diagnostic) {
        const issue = analyzed.value.diagnostic;

        std.debug.print("{s}: {s}\n", .{ issue.path, issue.message });

        return error.InvalidLexerSource;
    }

    const output = try compiler.zig.emit(allocator, analyzed.value.contract.program);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output });
}
