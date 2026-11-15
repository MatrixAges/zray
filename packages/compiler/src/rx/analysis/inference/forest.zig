const std = @import("std");
const Id = @import("types.zig").Id;
const enabled = @import("rx_options").generated_graph;

/// Parent compression changes the cache without changing the equivalence relation.
pub fn root(parents: []u32, id: Id) Id {
    const index = @backingInt(id);
    const first = parents[index];

    if (first == index or parents[first] == first) return @fromBackingInt(first);
    if (!enabled) return @fromBackingInt(seedRoot(parents, index, first));

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = @import("generated_rx_forest_root").executeValue(empty.allocator(), .{
        .parents = @ptrCast(&parents),
        .value = index,
    }) catch unreachable;

    return @fromBackingInt(result);
}

fn seedRoot(parents: []u32, index: u32, first: u32) u32 {
    var current = index;
    var next = first;

    while (next != current) {
        const grandparent = parents[next];

        parents[current] = grandparent;
        current = grandparent;
        next = parents[current];
    }

    return current;
}
