const zx = @import("zx");
const Kind = @import("../nodes.zig").Kind;
const Graph = @import("../types.zig");

pub fn borrow(comptime View: type, graph: *const Graph) View {
    const rows = graph.nodes.slice();
    const types = &graph.types.items;
    const kinds: []const Kind = rows.items(.kind);

    return .{
        .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds),
        .arguments = rows.items(.argument),
        .members = rows.items(.members),
        .type_kinds = types.kinds.items,
        .type_sizes = types.second.items,
    };
}
