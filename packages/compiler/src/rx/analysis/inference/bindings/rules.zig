const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Kind = @import("../nodes.zig").Kind;
pub const Status = enum { Void, Pending, Value };
pub const Collision = enum { Ignore, Defer, Conflict };
pub const Selection = struct { value: ?Graph.Id = null, multiple: bool = false };

pub fn view(comptime Topology: type, graph: *const Graph) std.meta.Child(@FieldType(Topology, "graph")) {
    const View = std.meta.Child(@FieldType(Topology, "graph"));
    const rows = graph.nodes.slice();
    const kinds: []const Kind = rows.items(.kind);

    return .{ .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds), .arguments = rows.items(.argument) };
}

pub fn status(graph: *const Graph, id: Graph.Id) Status {
    const index = @backingInt(graph.root(id));
    const kind = graph.nodes.items(.kind)[index];
    const argument = graph.nodes.items(.argument)[index];

    if (kind == .Unknown) return .Pending;
    if (kind == .Known and argument == @backingInt(@import("frontend").types.scalarId(.void))) return .Void;

    return .Value;
}

pub fn pair(graph: *const Graph, left: Graph.Id, right: Graph.Id, final: bool) Collision {
    const first = status(graph, left);

    if (first == .Void) return .Ignore;

    const second = status(graph, right);

    if (second == .Void) return .Ignore;

    return if (final or (first == .Value and second == .Value)) .Conflict else .Defer;
}

pub fn missing(graph: *const Graph, values: []const Graph.Id) ?usize {
    for (values, 0..) |value, index| {
        if (status(graph, value) == .Void) return index;
    }

    return null;
}

pub fn selectSeed(graph: *const Graph, candidates: []const Graph.Id) Selection {
    var result: Selection = .{};

    for (candidates) |candidate| {
        if (status(graph, candidate) == .Void) continue;
        if (result.value != null) result.multiple = true;

        result.value = candidate;
    }

    return result;
}
