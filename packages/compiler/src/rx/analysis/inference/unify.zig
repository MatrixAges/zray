const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Nodes = @import("nodes.zig");
const Plan = @import("unification/plan.zig");
const Commit = @import("unification/commit.zig");
const Fields = @import("unification/fields.zig");
const Occurs = @import("unification/occurs.zig");
const Frame = @import("unify/frame.zig");
const inline_frames = 8;
const inline_field_bytes = std.heap.page_size_min / 16;
const Stack = std.ArrayList(Frame);
const Pending = struct { frame: Frame, declared_names: []const []const u8 };

pub fn merge(graph: *Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!void {
    if (comptime !Plan.enabled) return @import("unify/seed.zig").merge(graph, left, right, span, depth);

    const work = try Plan.prepare(graph, left, right, span, depth);
    const frame = try prepare(graph, work, span) orelse return;

    return walk(graph, frame, span, depth);
}

fn prepare(graph: *Graph, work: Plan.Work, span: zx.Span) zx.Error!?Pending {
    switch (work.route) {
        .Same => return null,
        .Depth => return Occurs.depthLimit(graph, span),
        .Recursive => return Occurs.recursive(graph, span),
        .Left, .Right, .Known, .Child, .Tuple, .Object => {},
        else => |issue| return graph.reporter.fail(.type_mismatch, span, @import("unify/messages.zig").shape(issue)),
    }

    const rows = graph.nodes.slice();
    const parent: Graph.Id = @fromBackingInt(work.left);
    const child: Graph.Id = @fromBackingInt(work.right);
    const first = Commit.snapshot(rows, parent);
    const second = Commit.snapshot(rows, child);
    const shape = Nodes.encoded(rows, work.source);

    if (work.action == .Adopt) {
        try Commit.publish(graph, parent, child, first, second, shape, span);

        return null;
    }

    return .{
        .frame = .{
            .parent = parent,
            .child = child,
            .action = work.action,
            .left_operand = work.left_operand,
            .right_operand = work.right_operand,
            .first = first,
            .second = second,
            .shape = shape,
            .left_members = work.left_members,
            .right_members = work.right_members,
        },
        .declared_names = work.right_names,
    };
}

noinline fn walk(graph: *Graph, root: Pending, span: zx.Span, depth: usize) zx.Error!void {
    var frame_buffer: [inline_frames]Frame = undefined;
    var field_buffer: [inline_field_bytes]u8 = undefined;
    var frame_memory = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&frame_buffer), graph.scratch);
    var field_memory = std.heap.BufferFirstAllocator.init(&field_buffer, graph.scratch);
    const frames = frame_memory.allocator();
    const fields = field_memory.allocator();
    var stack: Stack = .empty;

    defer stack.deinit(frames);
    defer while (stack.pop()) |frame| frame.release(fields);

    try push(&stack, root, frames, fields);

    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        const child_depth = depth + stack.items.len;
        const next = frame.next(graph, child_depth);

        switch (next.step) {
            .Publish => {
                try frame.finish(graph, span);

                frame.release(fields);

                stack.items.len -= 1;
            },
            .Merge, .MergeKnown => {
                const left: Graph.Id = @fromBackingInt(next.left);

                const work = if (next.step == .MergeKnown)
                    try Plan.prepare(graph, left, try graph.known(@fromBackingInt(next.right), span), span, child_depth)
                else
                    try Plan.rooted(graph, left, @fromBackingInt(next.right));

                const child = try prepare(graph, work, span) orelse continue;

                try push(&stack, child, frames, fields);
            },
            .MissingField => return graph.reporter.fail(.type_mismatch, span, Fields.missing_message),
            .Depth => return Occurs.depthLimit(graph, span),
            .Skip => unreachable,
        }
    }
}

fn push(stack: *Stack, initial: Pending, frames: std.mem.Allocator, fields: std.mem.Allocator) std.mem.Allocator.Error!void {
    try stack.ensureUnusedCapacity(frames, 1);

    const frame = &stack.unusedCapacitySlice()[0];

    frame.* = initial.frame;

    try frame.alignFields(initial.declared_names, fields);

    stack.items.len += 1;
}
