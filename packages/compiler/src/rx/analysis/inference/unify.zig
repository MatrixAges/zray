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

pub fn merge(graph: *Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!void {
    if (comptime !Plan.enabled) return @import("unify/seed.zig").merge(graph, left, right, span, depth);

    const frame = try prepare(graph, left, right, span, depth) orelse return;

    return walk(graph, frame, span, depth);
}

fn prepare(graph: *Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!?Frame {
    const work = try Plan.prepare(graph, left, right, span, depth);

    switch (work.route) {
        .Same => return null,
        .Depth => return Occurs.depthLimit(graph, span),
        .Recursive => return Occurs.recursive(graph, span),
        .Left, .Right, .Known, .Child, .Tuple, .Object => {},
        else => |issue| return graph.reporter.fail(.type_mismatch, span, @import("unify/messages.zig").shape(issue)),
    }

    const rows = graph.nodes.slice();
    const first = Commit.snapshot(rows, work.left);
    const second = Commit.snapshot(rows, work.right);
    const shape = Nodes.encoded(rows, work.source);

    if (work.action == .Adopt) {
        try Commit.publish(graph, work.left, work.right, first, second, shape, span);

        return null;
    }

    return .{ .work = work, .first = first, .second = second, .shape = shape };
}

noinline fn walk(graph: *Graph, root: Frame, span: zx.Span, depth: usize) zx.Error!void {
    var frame_buffer: [inline_frames]Frame = undefined;
    var field_buffer: [inline_field_bytes]u8 = undefined;
    var frame_memory = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&frame_buffer), graph.scratch);
    var field_memory = std.heap.BufferFirstAllocator.init(&field_buffer, graph.scratch);
    const frames = frame_memory.allocator();
    const fields = field_memory.allocator();
    var stack: Stack = .empty;

    defer stack.deinit(frames);
    defer while (stack.pop()) |frame| frame.release(fields);

    try push(graph, &stack, root, frames, fields);

    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        const next = frame.next(graph);

        switch (next.step) {
            .Publish => {
                try frame.finish(graph, span);

                frame.release(fields);

                stack.items.len -= 1;
            },
            .Merge, .MergeKnown => {
                const right = if (next.step == .MergeKnown)
                    try graph.known(@fromBackingInt(next.right), span)
                else
                    @as(Graph.Id, @fromBackingInt(next.right));

                const child = try prepare(graph, @fromBackingInt(next.left), right, span, depth + stack.items.len) orelse continue;

                try push(graph, &stack, child, frames, fields);
            },
            .MissingField => return graph.reporter.fail(.type_mismatch, span, Fields.missing_message),
        }
    }
}

fn push(graph: *const Graph, stack: *Stack, initial: Frame, frames: std.mem.Allocator, fields: std.mem.Allocator) std.mem.Allocator.Error!void {
    try stack.ensureUnusedCapacity(frames, 1);

    var frame = initial;

    try frame.admit(graph, fields);

    stack.appendAssumeCapacity(frame);
}
