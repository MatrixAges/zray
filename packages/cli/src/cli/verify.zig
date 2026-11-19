const std = @import("std");
const compiler = @import("compiler");
const Context = @import("compile.zig").Context;
pub const workspace_allocator = std.heap.page_allocator;

pub fn run(context: Context, sources: []const compiler.project.Source, project: compiler.project.Options, cache: *compiler.project.SemanticCache) !bool {
    const allocator = context.allocator;
    const options = context.options;
    const writer = context.stderr;
    var analyzed = if (options.cache) try compiler.analyzeProjectIncremental(allocator, sources, project, cache) else try compiler.analyzeProjectWithCache(allocator, sources, project, &cache.parse_cache);

    defer analyzed.deinit();

    if (analyzed.value == .diagnostic) {
        try writer.print("verification: {s}\n", .{analyzed.value.diagnostic.message});

        return false;
    }

    return compiler.verification.check(context.io, workspace_allocator, analyzed.value.ir, sources, project.entry, .{ .solver = options.solver, .output = options.output }, writer);
}
