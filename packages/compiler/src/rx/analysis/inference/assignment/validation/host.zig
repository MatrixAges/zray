const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const Kind = @import("../../nodes.zig").Kind;
const Validation = @import("../validation.zig");
const rule = @import("generated_assignment_validation");
const Input = std.meta.Child(rule.Input);
const Columns = std.meta.Child(@FieldType(Input, "columns"));
const View = std.meta.Child(@FieldType(Columns, "graph"));
const Types = std.meta.Child(@FieldType(View, "types"));

const Frame = struct {
    graph: *Graph,
    resolver: *Graph.Resolver,
    edges: Validation.Edges,
    types: Types = undefined,
    fn bindTypes(self: *Frame) void {
        const table = &self.graph.types.items;

        self.types = .{ .kinds = table.kinds.items, .children = table.first.items };
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, resolver: *Graph.Resolver, edges: Validation.Edges) zx.Error!void {
    var frame: Frame = .{ .graph = graph, .resolver = resolver, .edges = edges };

    frame.bindTypes();

    const rows = graph.nodes.slice();
    const kinds: []const Kind = rows.items(.kind);
    const parents = graph.parents();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .columns = &.{
            .graph = &.{
                .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds),
                .arguments = rows.items(.argument),
                .types = &frame.types,
            },
            .edges = &.{
                .left = @ptrCast(edges.items(.value)),
                .right = @ptrCast(edges.items(.expected)),
            },
            .parents = @ptrCast(&parents),
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../../../project/workflow/errors.zig");

    rule.executeIn(empty.allocator(), &input) catch |err| return workflow.errorSet(err);
}

pub fn resolveAssignmentEndpoint(handle: *const anyopaque, node: u32) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const resolved = try frame.graph.resolve(@fromBackingInt(node), frame.resolver);

    frame.bindTypes();

    return @backingInt(resolved);
}

pub fn rejectAssignmentEdge(handle: *const anyopaque, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);

    return Validation.mismatch(frame.graph, frame.edges.items(.span)[@intCast(row)]);
}
