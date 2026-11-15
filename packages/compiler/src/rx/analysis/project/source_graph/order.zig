const std = @import("std");
const model = @import("model.zig");

pub fn build(allocator: std.mem.Allocator, backing: std.mem.Allocator, modules: model.Modules.Slice, ranges: model.Sources, adjacency: model.Adjacency, roots: []const u64, sources: []const @import("frontend").project.Source, reached: usize) std.mem.Allocator.Error!model.Scheduled {
    if (!@import("rx_options").generated_graph) return @import("seed.zig").build(allocator, backing, modules, ranges, roots, sources);

    const generated = @import("generated_source_schedule");
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const native_width = @bitSizeOf(usize) == 64 and @alignOf(u64) >= @alignOf(usize);
    const order_allocator = if (native_width) allocator else temporary;
    const ranked = try order_allocator.alloc(u64, reached);
    var retained = false;

    defer if (native_width and !retained) allocator.free(ranked);

    const plan = generated.executeValue(temporary, &.{
        .offsets = adjacency.starts,
        .ends = adjacency.ends,
        .targets = adjacency.targets,
        .roots = roots,
        .order = ranked,
        .order_out = @ptrCast(&ranked),
    }) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    if (plan.cycle) |cycle| {
        const owner: usize = @intCast(cycle.owner);
        const module = modules.get(owner);
        var source_index = adjacency.starts[owner];

        for (module.dependencies) |edge| {
            if (edge.target != .source) continue;
            if (source_index == cycle.edge) return model.cycle(module, ranges.at(owner), edge, sources);

            source_index += 1;
        }

        unreachable;
    }

    std.debug.assert(plan.count == reached);

    const order: []const usize = if (native_width) @ptrCast(ranked) else try retain(allocator, ranked);

    errdefer if (!native_width) allocator.free(order);

    const batch_ends = try retain(allocator, plan.batch_ends);

    retained = true;

    return .{ .schedule = .{ .order = order, .batch_ends = batch_ends } };
}

fn retain(allocator: std.mem.Allocator, indices: []const u64) std.mem.Allocator.Error![]const usize {
    if (@bitSizeOf(usize) == 64 and @alignOf(u64) >= @alignOf(usize)) return allocator.dupe(usize, @ptrCast(indices));

    const output = try allocator.alloc(usize, indices.len);

    for (output, indices) |*index, value| index.* = @intCast(value);

    return output;
}
