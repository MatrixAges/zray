const zx = @import("zx");
const Graph = @import("../types.zig");
const View = @import("view.zig");
const Access = @import("access.zig");

pub fn borrow(comptime Object: type, graph: *const Graph, root: Graph.Id) Object {
    const fields = View.read(graph, root);

    return .{
        .mode = @fromBackingInt(@backingInt(fields.mode)),
        .restricted = graph.nodes.items(.allowed)[@backingInt(root)] != null,
        .names = fields.names,
        .values = fields.values,
    };
}

pub fn field(graph: *Graph, object: Graph.Id, root: Graph.Id, name: []const u8, plan: anytype, span: zx.Span) zx.Error!Graph.Id {
    return switch (plan.action) {
        .Field => Access.at(graph, object, root, name, span),
        .Append => append(graph, root, name, span),
        .Register => graph.known(@fromBackingInt(plan.value), span),
        .Reuse => @fromBackingInt(plan.value),
    };
}

fn append(graph: *Graph, root: Graph.Id, name: []const u8, span: zx.Span) zx.Error!Graph.Id {
    const index = @backingInt(root);
    const members = graph.nodes.items(.members)[index];
    const fields = Graph.Fields.fromValues(@ptrCast(members));

    return Access.append(graph, index, fields, name, span);
}
