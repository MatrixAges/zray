const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Fields = @import("../unification/fields.zig");
const Commit = @import("../unification/commit.zig");
const errors = @import("../../project/workflow/errors.zig");
const merge_rule = @import("generated_rx_merge_unification");
const walk_rule = @import("generated_rx_walk_unification");
const prepare_rule = @import("generated_rx_prepare_unification_frame");
const plan_rule = @import("generated_rx_plan_unification_frame");
const Merge = std.meta.Child(merge_rule.Input);
const Request = std.meta.Child(walk_rule.Input);
const Plan = std.meta.Child(prepare_rule.Input);
const View = std.meta.Child(@FieldType(Plan, "view"));
const Candidate = std.meta.Child(@FieldType(Merge, "candidate"));
const Stack = std.meta.Child(@FieldType(Request, "stack"));
const Row = std.meta.Child(@FieldType(Stack, "frame"));
const Frame = std.meta.Child(@FieldType(Candidate, "frame"));
const Known = std.meta.Child(@FieldType(Stack, "known"));
const inline_frames = 8;
const inline_field_bytes = std.heap.page_size_min / 16;

const Target = struct {
    graph: *Graph,
    span: zx.Span,
    parents: []u32 = undefined,
    view: View = undefined,
    nodes: std.meta.Child(@FieldType(View, "graph")) = undefined,
    types: std.meta.Child(@FieldType(View, "types")) = undefined,
    pending: Frame = undefined,
    candidate: Candidate = undefined,
    walk: *Walk = undefined,
    fn bind(self: *Target) void {
        const graph = self.graph;
        const rows = graph.nodes.slice();
        const types = &graph.types.items;

        self.parents = graph.parents();

        const kinds: []const @import("../nodes.zig").Kind = rows.items(.kind);

        self.nodes = .{
            .kinds = zx.columns.slice(@FieldType(@TypeOf(self.nodes), "kinds"), kinds),
            .members = rows.items(.members),
            .arguments = rows.items(.argument),
        };

        self.types = .{
            .kinds = types.kinds.items,
            .arguments = types.first.items,
            .sizes = types.second.items,
            .children = types.children.items,
            .field_names = types.field_names.items,
            .field_values = types.field_types.items,
        };

        self.view = .{
            .parents = self.parents,
            .graph = &self.nodes,
            .types = &self.types,
            .kind_bytes = std.mem.sliceAsBytes(rows.items(.kind)),
            .allowed = rows.items(.allowed),
            .fallback = rows.items(.fallback),
        };
    }
    fn borrow(handle: *anyopaque) *Target {
        return @ptrCast(@alignCast(handle));
    }
};

const Stored = struct { snapshot: Frame, fields: Fields.Alignment = .{} };

const Walk = struct {
    frames: std.mem.Allocator,
    fields: std.mem.Allocator,
    stack: std.ArrayList(Stored) = .empty,
    view: Stack = undefined,
    row: Row = undefined,
    known: Known = undefined,
    fn current(self: *Walk) *Stored {
        return &self.stack.items[self.stack.items.len - 1];
    }
    fn bind(self: *Walk) void {
        const item = self.current();

        self.row = .{ .snapshot = &item.snapshot, .positions = item.fields.positions[0..item.fields.scanned] };
    }
};

pub fn merge(graph: *Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!void {
    var target: Target = .{ .graph = graph, .span = span };

    target.bind();

    target.candidate = .{ .frame = &target.pending };

    try prepareUnificationFrame(@ptrCast(&target), @backingInt(left), @backingInt(right), depth, false);

    const input: Merge = .{ .target = @ptrCast(&target), .candidate = &target.candidate, .depth = depth };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(merge_rule.executeValue, empty.allocator(), &input) catch |err| return errors.errorSet(err);

    if (result) |issue| return target.graph.reporter.fail(if (issue.depth) .unsupported else .type_mismatch, target.span, issue.message);
}

pub fn prepareUnificationFrame(handle: *anyopaque, left: u32, right: u32, depth: u64, rooted: bool) std.mem.Allocator.Error!void {
    const target = Target.borrow(handle);

    const input: std.meta.Child(plan_rule.Input) = .{
        .graph = &target.nodes,
        .types = &target.types,
        .parents = target.parents,
        .left = left,
        .right = right,
        .depth = depth,
        .rooted = rooted,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const allocator = empty.allocator();
    const work = zx.columns.invoke(plan_rule.executeValue, allocator, &input) catch unreachable;
    const projected = zx.columns.view(std.meta.Child(@FieldType(Plan, "plan")), work);
    const request: Plan = .{ .view = &target.view, .plan = &projected };
    const captured = zx.columns.invoke(prepare_rule.executeValue, allocator, &request) catch unreachable;

    target.pending = zx.columns.view(Frame, captured);
}

pub noinline fn walkUnificationFrames(handle: *anyopaque, depth: u64) zx.Error!void {
    const target = Target.borrow(handle);
    const allocator = target.graph.scratch;
    var frame_buffer: [inline_frames]Stored = undefined;
    var field_buffer: [inline_field_bytes]u8 = undefined;
    var frame_memory = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&frame_buffer), allocator);
    var field_memory = std.heap.BufferFirstAllocator.init(&field_buffer, allocator);
    var state: Walk = .{ .frames = frame_memory.allocator(), .fields = field_memory.allocator() };

    defer state.stack.deinit(state.frames);
    defer while (state.stack.pop()) |frame| state.fields.free(frame.fields.positions);

    state.known = target.graph.pending.known_types.borrow(Known);

    state.view = .{
        .frame = &state.row,
        .parents = target.parents,
        .known = &state.known,
    };

    target.walk = &state;

    const input: Request = .{ .target = @ptrCast(handle), .candidate = &target.candidate, .stack = &state.view, .depth = depth };
    var cursor_buffer: [256]u8 = undefined;
    var cursor_memory = std.heap.BufferFirstAllocator.init(&cursor_buffer, allocator);
    const result = zx.columns.invoke(walk_rule.executeValue, cursor_memory.allocator(), &input) catch |err| return errors.errorSet(err);

    if (result) |issue| return target.graph.reporter.fail(if (issue.depth) .unsupported else .type_mismatch, target.span, issue.message);
}

pub fn appendUnificationFrame(handle: *anyopaque) std.mem.Allocator.Error!void {
    const target = Target.borrow(handle);
    const state = target.walk;

    try state.stack.append(state.frames, .{ .snapshot = target.pending });

    state.bind();
}

pub fn alignUnificationFields(handle: *anyopaque, existing_names: ?[]const []const u8, existing_values: []const u32, incoming_values: []const u32, closed: bool) std.mem.Allocator.Error!void {
    const state = Target.borrow(handle).walk;
    const existing = existing_names orelse Graph.Fields.viewFromValues(@ptrCast(existing_values)).names();
    const incoming = Graph.Fields.viewFromValues(@ptrCast(incoming_values)).names();

    state.current().fields = try Fields.alignFields(state.fields, existing, incoming, closed);
    state.bind();
}

pub fn popUnificationFrame(handle: *anyopaque) void {
    const state = Target.borrow(handle).walk;
    const frame = state.stack.pop().?;

    state.fields.free(frame.fields.positions);

    if (state.stack.items.len != 0) state.bind();
}

pub fn mergeUnificationFields(handle: *anyopaque) std.mem.Allocator.Error![]const u32 {
    const target = Target.borrow(handle);
    const frame = target.walk.current();
    const left = target.graph.mutableFields(frame.snapshot.left_members);
    const right = Graph.Fields.viewFromValues(@ptrCast(frame.snapshot.right_members));
    const published = try Fields.publish(&target.graph.field_buffers, target.graph.allocator, left, right, frame.fields);

    return @ptrCast(published.values());
}

pub fn commitUnification(handle: *anyopaque, parent: u32, child: u32, first_allowed: ?u16, second_allowed: ?u16, first_fallback: ?u8, second_fallback: ?u8, kind: u8, argument: u32, members: []const u32) zx.Error!void {
    const target = Target.borrow(handle);

    try Commit.publish(
        target.graph,
        @fromBackingInt(parent),
        @fromBackingInt(child),
        .{ .allowed = first_allowed, .fallback = first_fallback },
        .{ .allowed = second_allowed, .fallback = second_fallback },
        .{ .kind = @fromBackingInt(@intCast(kind)), .argument = argument, .members = members },
        target.span,
    );
}

pub fn internUnificationType(handle: *anyopaque, type_id: u32) zx.Error!u32 {
    const target = Target.borrow(handle);
    const result = try target.graph.known(@fromBackingInt(type_id), target.span);

    target.bind();

    target.walk.view.parents = target.parents;
    target.walk.known = target.graph.pending.known_types.borrow(Known);

    return @backingInt(result);
}
