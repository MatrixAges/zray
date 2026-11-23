const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../../types.zig");
const Kind = @import("../../../nodes.zig").Kind;
const Assignment = @import("../../../assignment.zig");
const Depth = @import("../../depth.zig");
const rule = @import("generated_assignment_materialize");
const Input = std.meta.Child(rule.Input);
const Views = std.meta.Child(@FieldType(Input, "views"));
const Nodes = std.meta.Child(@FieldType(Views, "nodes"));

const Frame = struct {
    graph: *Graph,
    nodes: Nodes = undefined,
    parents: []u32 = undefined,
    fn bind(self: *Frame) void {
        const rows = self.graph.nodes.slice();
        const kinds: []const Kind = rows.items(.kind);

        self.parents = self.graph.parents();
        self.nodes = .{ .kinds = zx.columns.slice(@FieldType(Nodes, "kinds"), kinds), .allowed = rows.items(.allowed) };
    }
};

pub fn run(graph: *Graph, base: Assignment.Base, scratch: std.mem.Allocator) zx.Error!void {
    const prepared = try Depth.prepare(graph, scratch);
    const indexes = graph.pending.indexes.slice();
    const words = try scratch.alloc(u64, prepared.deferred_words);

    @memset(words, 0);

    var frame: Frame = .{ .graph = graph };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .views = &.{
            .nodes = &frame.nodes,
            .depths = prepared.depths,
            .deferred = words,
            .classes = &.{ .groups = base.parents, .representatives = base.representatives },
            .parents = @ptrCast(&frame.parents),
        },
        .indexes = &.{
            .values = @ptrCast(indexes.items(.value)),
            .resolved = indexes.items(.resolved),
            .words = @ptrCast(&words),
            .first = prepared.first_deferred,
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../../../../project/workflow/errors.zig");

    rule.executeIn(empty.allocator(), &input) catch |err| return workflow.errorSet(err);
}

pub fn materializeAssignment(handle: *const anyopaque, node: u32, payload: u32, layers: u64) zx.Error!void {
    const frame: *Frame = @ptrCast(@alignCast(@constCast(handle)));

    // Each merge keeps the current root. Later roots can disappear but cannot acquire deferred members.
    try Assignment.apply(frame.graph, node, @fromBackingInt(payload), layers);

    frame.bind();
}
