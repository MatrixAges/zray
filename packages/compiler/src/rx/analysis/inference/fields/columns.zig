const Graph = @import("../types.zig");

pub fn borrow(comptime View: type, graph: *const Graph) View {
    const rows = graph.nodes.slice();
    const types = &graph.types.items;

    return .{
        .kinds = rows.items(.kind),
        .arguments = rows.items(.argument),
        .members = rows.items(.members),
        .type_kinds = types.kinds.items,
        .type_sizes = types.second.items,
    };
}
