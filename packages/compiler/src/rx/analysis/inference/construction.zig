const zx = @import("zx");
const Graph = @import("types.zig");
const ObjectClosure = @import("object_closure.zig");

pub const Part = struct { name: ?[]const u8, value: Graph.Id, span: zx.Span };

pub const Object = struct {
    result: Graph.Id,
    first: u64,
    count: u64,
    span: zx.Span,
    pub fn part(self: Object, graph: *const Graph, index: usize) Part {
        return graph.pending.construction_parts.get(@as(usize, @intCast(self.first)) + index);
    }
};

pub fn replay(graph: *Graph, closure: *ObjectClosure, final: bool) zx.Error!void {
    const objects = graph.pending.constructions.slice();

    if (comptime !@import("rx_options").generated_graph) {
        for (0..objects.len) |row| try @import("construction/seed.zig").propagate(graph, closure, objects.get(row), final);

        return;
    }

    return @import("construction/host.zig").run(graph, closure, objects, final);
}
