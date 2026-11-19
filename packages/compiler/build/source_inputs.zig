const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const analysis = @import("rx_analysis");

pub fn reachable(allocator: std.mem.Allocator, backing: std.mem.Allocator, modules: []const rx.ModuleSource, sources: []const compiler.project.Source, entries: []const []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache) ![]const rx.ModuleSource {
    if (entries.len == 0) return error.NoEntries;

    var result = try analysis.project.source_graph.build(backing, .{ .entry = entries[0], .additional_roots = entries[1..], .modules = modules, .sources = sources, .project = project, .parse_cache = cache });

    defer result.deinit();

    if (result.value == .diagnostic) {
        const issue = result.value.diagnostic;

        std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message });

        return error.InvalidSourceGraph;
    }

    const rows = try analysis.project.source_graph.orderedRows(backing, &result.value.graph, .rx);

    defer backing.free(rows);

    const selected = try allocator.alloc(rx.ModuleSource, rows.len);

    try compiler.source_inputs.order.select(rx.ModuleSource, modules, rows, selected);

    return selected;
}
