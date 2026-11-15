const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");

pub const Columns = struct {
    initial: []const u32 = &.{},
    registered: []const u32 = &.{},
};

pub fn collect(graph: *Graph, allocator: std.mem.Allocator) zx.Error!Columns {
    const start = graph.nodes.len;
    const initial = try scan(graph, allocator, 0, start);
    const limit = graph.nodes.len;
    // The initial scan follows every newly registered child before advancing.
    const registered = try scan(graph, allocator, start, limit);

    std.debug.assert(graph.nodes.len == limit);

    return .{ .initial = initial, .registered = registered };
}

fn scan(graph: *Graph, allocator: std.mem.Allocator, start: usize, limit: usize) zx.Error![]const u32 {
    const generated = @import("generated_assignment_payloads");
    const Request = @typeInfo(@TypeOf(generated.executeState)).@"fn".param_types[1].?;
    const View = std.meta.Child(@FieldType(Request, "graph"));
    const payloads = try allocator.alloc(u32, limit - start);
    var next = start;
    var source: u32 = if (start < limit) @intCast(start) else 0;
    var remaining: ?u64 = null;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (next < limit) {
        const rows = graph.nodes.slice();

        const view: View = .{
            .kinds = rows.items(.kind),
            .arguments = rows.items(.argument),
            .types = &.{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items },
        };

        const parents = graph.parents();

        const result = generated.executeState(empty.allocator(), .{
            .graph = &view,
            .parents = @ptrCast(&parents),
            .payloads = @ptrCast(&payloads),
            .start = start,
            .limit = limit,
            .next = next,
            .source = source,
            .origin = source,
            .remaining = remaining,
            .action = .Scan,
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        next = @intCast(result.next);

        switch (result.action) {
            .Scan => return payloads,
            .Register => {
                const span = rows.items(.span)[result.origin];

                source = @backingInt(try graph.known(@fromBackingInt(result.source), span));
                remaining = result.remaining;
            },
            .Depth => return graph.reporter.fail(.unsupported, rows.items(.span)[result.origin], "type inference nesting exceeds 256 levels"),
        }
    }

    return payloads;
}
