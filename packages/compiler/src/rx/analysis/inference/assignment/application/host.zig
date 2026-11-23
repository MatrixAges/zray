const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const Kind = @import("../../nodes.zig").Kind;
const Base = @import("../base.zig");
const Payloads = @import("../classes/payloads.zig").Columns;
const Known = @import("../../known.zig");
const workflow = @import("../../../project/workflow/errors.zig");
const merge = @import("generated_assignment_propagate");
const MergeInput = std.meta.Child(merge.Input);
const View = std.meta.Child(@FieldType(MergeInput, "view"));
const Nodes = std.meta.Child(@FieldType(View, "graph"));
const Types = std.meta.Child(@FieldType(Nodes, "types"));
const Table = std.meta.Child(@FieldType(View, "known"));

const Frame = struct {
    graph: *Graph,
    allocator: std.mem.Allocator,
    view: View = undefined,
    nodes: Nodes = undefined,
    types: Types = undefined,
    known: Table = undefined,
    parents: []u32 = undefined,
    remaining: u64 = 0,
    payloads: Payloads = .{},
    active: []u32 = &.{},
    limit: usize = 0,
    fn bind(self: *Frame) void {
        const graph = self.graph;
        const rows = graph.nodes.slice();
        const kinds: []const Kind = rows.items(.kind);
        const types = &graph.types.items;

        self.parents = graph.parents();
        self.types = .{ .kinds = types.kinds.items, .children = types.first.items };

        self.nodes = .{
            .kinds = zx.columns.slice(@FieldType(Nodes, "kinds"), kinds),
            .arguments = rows.items(.argument),
            .types = &self.types,
        };

        self.known = graph.pending.known_types.borrow(Table);
        self.view = .{ .graph = &self.nodes, .allowed = rows.items(.allowed), .parents = @ptrCast(&self.parents), .known = &self.known };
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn allocate(self: *Frame, first: usize) std.mem.Allocator.Error!void {
        self.limit = self.graph.nodes.len;
        self.active = try self.allocator.alloc(u32, self.limit - first);
    }
};

pub fn propagate(graph: *Graph, base: Base) zx.Error!void {
    var frame: Frame = .{ .graph = graph, .allocator = graph.scratch };

    frame.bind();

    const input: MergeInput = .{
        .frame = @ptrCast(&frame),
        .view = &frame.view,
        .classes = &.{ .groups = base.parents, .representatives = base.representatives },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    merge.executeIn(empty.allocator(), &input) catch |err| return failure(err);
}

pub fn collect(graph: *Graph, allocator: std.mem.Allocator) zx.Error!Payloads {
    const rule = @import("generated_assignment_collect_payloads");
    const Input = std.meta.Child(rule.Input);
    var frame: Frame = .{ .graph = graph, .allocator = allocator };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .view = &frame.view,
        .payloads = @ptrCast(&frame.active),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), &input) catch |err| return failure(err);
    std.debug.assert(graph.nodes.len == frame.limit);

    return frame.payloads;
}

pub fn beginInitialAssignmentPayloads(handle: *const anyopaque) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    try frame.allocate(0);

    frame.payloads.initial = frame.active;

    return frame.limit;
}

pub fn beginRegisteredAssignmentPayloads(handle: *const anyopaque, first: u64) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    try frame.allocate(@intCast(first));

    frame.payloads.registered = frame.active;

    return frame.limit;
}

pub fn registerAssignmentPayload(handle: *const anyopaque, node: u32, value: u32, remaining: u64) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const span = graph.nodes.items(.span)[node];
    const registered = try Known.registerPayload(graph, value, remaining, span);

    frame.remaining = registered.remaining;

    frame.bind();

    return @backingInt(registered.node);
}

pub fn remainingAssignmentDepth(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).remaining;
}

pub fn rejectAssignmentDepth(handle: *const anyopaque, node: u32) zx.Error!void {
    const graph = Frame.borrow(handle).graph;

    return graph.reporter.fail(.unsupported, graph.nodes.items(.span)[node], "type inference nesting exceeds 256 levels");
}

pub fn mergeAssignmentClass(handle: *const anyopaque, row: u64, other: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const index: usize = @intCast(row);

    try graph.unify(@fromBackingInt(@as(u32, @intCast(index))), @fromBackingInt(other), graph.nodes.items(.span)[index]);

    frame.bind();
}

fn failure(err: anyerror) zx.Error {
    return switch (err) {
        error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => workflow.errorSet(err),
    };
}
