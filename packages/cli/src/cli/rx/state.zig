const compiler = @import("compiler");
const store = @import("rx_analysis").store;
const Prepared = @import("analyze.zig").Result;

pub fn append(bundle: *compiler.zig.ModuleBundle, prepared: *const Prepared, cache: ?*compiler.zig.GenerationCache) !void {
    const allocator = bundle.arena.allocator();
    const program = &prepared.analysis.value.ir;

    if (program.stores.count() == 0) return;

    const initializers = try store.collectInitializers(allocator, prepared.store_definitions, program, &.{});

    try compiler.zig.store_initializers.append(bundle, .{ .analysis = &prepared.analysis, .initializers = initializers, .cache = cache });
    try compiler.zig.state.append(bundle, .{ .analysis = &prepared.analysis, .cache = cache });
}
