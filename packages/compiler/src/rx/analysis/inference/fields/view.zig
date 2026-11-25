const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const entry = @import("generated_rx_object_view");
const Self = @This();
pub const Mode = entry.Output;

pub const Shape = struct {
    kind: Nodes.Kind,
    type_kind: u8,
    argument: u32,
    restricted: bool,
};

mode: Mode,
names: []const []const u8 = &.{},

values: []const u32 = &.{},

pub fn describe(graph: *const Graph, root: Graph.Id) Shape {
    const index = @backingInt(root);
    const rows = graph.nodes.slice();
    const kind = rows.items(.kind)[index];
    const argument = rows.items(.argument)[index];

    return .{
        .kind = kind,
        .type_kind = if (kind == .Known) graph.types.items.kinds.items[argument] else 0,
        .argument = argument,
        .restricted = rows.items(.allowed)[index] != null,
    };
}

pub fn read(graph: *const Graph, root: Graph.Id) Self {
    return readMode(graph, root, classify(describe(graph, root)));
}

pub fn classify(shape: Shape) Mode {
    const Input = std.meta.Child(entry.Input);
    const input: Input = .{ .kind = shape.kind, .type_kind = shape.type_kind };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn readMode(graph: *const Graph, root: Graph.Id, mode: Mode) Self {
    switch (mode) {
        .Inferred => {
            const members = graph.nodes.items(.members)[@backingInt(root)];
            const fields = Graph.Fields.viewFromValues(@ptrCast(members));

            return .{ .mode = mode, .names = fields.names(), .values = members };
        },
        .Declared => {
            const types = &graph.types.items;
            const type_id = graph.nodes.items(.argument)[@backingInt(root)];
            const first = types.first.items[type_id];
            const count = types.second.items[type_id];

            return .{ .mode = mode, .names = types.field_names.items[first..][0..count], .values = types.field_types.items[first..][0..count] };
        },
        else => return .{ .mode = mode },
    }
}
