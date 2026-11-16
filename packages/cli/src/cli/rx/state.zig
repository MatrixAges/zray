const std = @import("std");
const compiler = @import("compiler");
const store = @import("rx_analysis").store;
const Prepared = @import("analyze.zig").Result;

pub fn append(bundle: *compiler.zig.ModuleBundle, prepared: *const Prepared, cache: ?*compiler.zig.GenerationCache) !void {
    const program = &prepared.analysis.value.ir;

    if (program.stores.count() == 0) return;

    var scratch = std.heap.ArenaAllocator.init(bundle.arena.child_allocator);

    defer scratch.deinit();

    const initializers = try store.collectInitializers(scratch.allocator(), prepared.store_definitions, program, &.{});

    try compiler.zig.store_initializers.append(bundle, .{ .analysis = &prepared.analysis, .borrowed_initializers = initializers, .cache = cache });
    try compiler.zig.state.append(bundle, .{ .analysis = &prepared.analysis, .cache = cache });
}
