const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");

pub fn borrowType(comptime Request: type) type {
    const View = std.meta.Child(@FieldType(Request, "graph"));
    const Types = std.meta.Child(@FieldType(View, "types"));

    return struct {
        graph: View,
        types: Types,
        known: std.meta.Child(@FieldType(Request, "known")),
        parents: []u32,
        pub fn bind(self: *@This(), graph: *const Graph) void {
            const rows = graph.nodes.slice();
            const kinds: []const Nodes.Kind = rows.items(.kind);

            self.bindTypes(graph);

            self.graph = .{
                .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds),
                .arguments = rows.items(.argument),
                .types = &self.types,
            };

            self.known = graph.pending.known_types.borrow(@TypeOf(self.known));
            self.parents = graph.parents();
        }

        pub fn bindTypes(self: *@This(), graph: *const Graph) void {
            self.types = .{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items };
        }
    };
}
