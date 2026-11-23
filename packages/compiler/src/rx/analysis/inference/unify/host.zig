const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Unification = @import("../unify.zig");
const Plan = @import("../unification/plan.zig");
const Occurs = @import("../unification/occurs.zig");
const Fields = @import("../unification/fields.zig");
const Frame = @import("frame.zig");
const inline_frames = 8;
const inline_field_bytes = std.heap.page_size_min / 16;
const rule = @import("generated_rx_walk_unification");
const Input = std.meta.Child(rule.Input);
const View = std.meta.Child(@FieldType(Input, "view"));
const Advance = std.meta.Child(@FieldType(View, "advance"));
const Pair = std.meta.Child(@FieldType(Advance, "pair"));
const Known = std.meta.Child(@FieldType(Advance, "known"));

const Walk = struct {
    graph: *Graph,
    span: zx.Span,
    depth: usize,
    frames: std.mem.Allocator,
    fields: std.mem.Allocator,
    stack: std.ArrayList(Frame) = .empty,
    view: View = undefined,
    advance: Advance = undefined,
    pair: Pair = undefined,
    known: Known = undefined,
    parents: []u32 = undefined,
    fn push(self: *Walk, pending: Unification.Pending) std.mem.Allocator.Error!void {
        try self.stack.ensureUnusedCapacity(self.frames, 1);

        const frame = &self.stack.unusedCapacitySlice()[0];

        frame.* = pending.frame;

        try frame.alignFields(pending.declared_names, self.fields);

        self.stack.items.len += 1;
    }
    fn bind(self: *Walk) void {
        self.view.active = self.stack.items.len != 0;

        if (!self.view.active) return;

        const frame = &self.stack.items[self.stack.items.len - 1];

        self.parents = self.graph.parents();
        self.known = self.graph.pending.known_types.borrow(Known);

        self.pair = .{
            .action = zx.columns.view(@FieldType(Pair, "action"), frame.action),
            .position = frame.position,
            .left_operand = frame.left_operand,
            .right_operand = frame.right_operand,
            .left_members = frame.left_members,
            .right_members = frame.right_members,
            .positions = frame.fields.positions[0..frame.fields.scanned],
        };

        self.advance = .{ .pair = &self.pair, .known = &self.known, .parents = @ptrCast(&self.parents), .depth = self.depth + self.stack.items.len };
    }

    fn borrow(handle: *const anyopaque) *Walk {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub noinline fn walk(graph: *Graph, root: Unification.Pending, span: zx.Span, depth: usize) zx.Error!void {
    var frame_buffer: [inline_frames]Frame = undefined;
    var field_buffer: [inline_field_bytes]u8 = undefined;
    var frame_memory = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&frame_buffer), graph.scratch);
    var field_memory = std.heap.BufferFirstAllocator.init(&field_buffer, graph.scratch);

    var state: Walk = .{
        .graph = graph,
        .span = span,
        .depth = depth,
        .frames = frame_memory.allocator(),
        .fields = field_memory.allocator(),
    };

    defer state.stack.deinit(state.frames);
    defer while (state.stack.pop()) |frame| frame.release(state.fields);

    try state.push(root);

    state.view = .{ .active = true, .advance = &state.advance };

    state.bind();

    const input: Input = .{ .frame = @ptrCast(&state), .view = &state.view };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../../project/workflow/errors.zig");

    rule.executeIn(empty.allocator(), &input) catch |err| return workflow.errorSet(err);
}

pub fn publishUnificationFrame(handle: *const anyopaque) zx.Error!void {
    const state = Walk.borrow(handle);
    const frame = &state.stack.items[state.stack.items.len - 1];

    try frame.finish(state.graph, state.span);

    frame.release(state.fields);

    state.stack.items.len -= 1;

    state.bind();
}

pub fn enterUnificationChild(handle: *const anyopaque, position: u64, left: u32, right: u32, known: bool) zx.Error!void {
    const state = Walk.borrow(handle);
    const graph = state.graph;
    state.stack.items[state.stack.items.len - 1].position = position;

    const work = if (known)
        try Plan.prepare(graph, @fromBackingInt(left), try graph.known(@fromBackingInt(right), state.span), state.span, state.advance.depth)
    else
        try Plan.rooted(graph, @fromBackingInt(left), @fromBackingInt(right));

    if (try Unification.prepare(graph, work, state.span)) |pending| try state.push(pending);

    state.bind();
}

pub fn rejectUnificationChild(handle: *const anyopaque, deep: bool) zx.Error!void {
    const state = Walk.borrow(handle);

    if (deep) return Occurs.depthLimit(state.graph, state.span);

    return state.graph.reporter.fail(.type_mismatch, state.span, Fields.missing_message);
}
