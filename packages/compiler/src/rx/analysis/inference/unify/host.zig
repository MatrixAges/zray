const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Fields = @import("../unification/fields.zig");
const Commit = @import("../unification/commit.zig");
const errors = @import("../../project/workflow/errors.zig");
const execution = @import("../../project/workflow/execute.zig");
const merge_rule = @import("generated_rx_merge_unification");
const prepare_rule = @import("generated_rx_prepare_unification_frame");
const plan_rule = @import("generated_rx_plan_unification_frame");
const Merge = std.meta.Child(merge_rule.Input);
const Plan = std.meta.Child(prepare_rule.Input);
const View = std.meta.Child(@FieldType(Plan, "view"));
const Candidate = std.meta.Child(@FieldType(Merge, "candidate"));
const Stack = std.meta.Child(@FieldType(Merge, "stack"));
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
    const backing = graph.scratch;
    var frame_buffer: [inline_frames]Stored = undefined;
    var field_buffer: [inline_field_bytes]u8 = undefined;
    var frame_memory = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&frame_buffer), backing);
    var field_memory = std.heap.BufferFirstAllocator.init(&field_buffer, backing);
    var walk: Walk = .{ .frames = frame_memory.allocator(), .fields = field_memory.allocator() };

    defer walk.stack.deinit(walk.frames);
    defer while (walk.stack.pop()) |frame| walk.fields.free(frame.fields.positions);

    var target: Target = .{ .graph = graph, .span = span, .walk = &walk };

    target.bind();

    target.candidate = .{ .frame = &target.pending };

    const input: Merge = .{
        .left = @backingInt(left),
        .right = @backingInt(right),
        .candidate = &target.candidate,
        .stack = &walk.view,
        .depth = depth,
    };

    const Store = std.meta.Child(@FieldType(merge_rule.zx_pending, "store_0"));

    const Host = struct {
        target: *Target,
        reply: *std.meta.Child(Store),
        store_0: *Store,
        pub fn commit(host: *@This(), pending: merge_rule.zx_pending) zx.Error!void {
            const effect = pending.store_0 orelse return;
            const work = host.target;

            switch (effect.step) {
                .BeginWalk => beginWalk(work),
                .Prepare => prepareFrame(work, effect.left.?, effect.right.?, effect.depth.?, effect.rooted.?),
                .Push => try appendFrame(work),
                .Align => try alignFields(work.walk, effect.existing_names, effect.existing_values.?, effect.incoming_values.?, effect.closed.?),
                .Pop => popFrame(work.walk),
                .MergeFields => host.reply.merged = try publishFields(work),
                .Publish => try commitFrame(work, effect),
                .Intern => host.reply.id = try internType(work, effect.type_id.?),
            }
        }
    };

    var reply = execution.snapshot(std.meta.Child(Store), .{
        .step = .Prepare,
        .id = 0,
        .merged = @as([]const u32, &.{}),
    });

    var store: Store = &reply;
    var host: Host = .{ .target = &target, .reply = &reply, .store_0 = &store };
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    var cursor_buffer: [512]u8 = undefined;
    var cursor_memory = std.heap.BufferFirstAllocator.init(&cursor_buffer, arena.allocator());

    const result = merge_rule.executeIn(cursor_memory.allocator(), &input, &host) catch |err| return switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => errors.errorSet(err),
    };

    if (result) |issue| return graph.reporter.fail(if (issue.depth) .unsupported else .type_mismatch, span, issue.message);
}

fn prepareFrame(target: *Target, left: u32, right: u32, depth: u64, rooted: bool) void {
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

fn beginWalk(target: *Target) void {
    const state = target.walk;

    state.known = target.graph.pending.known_types.borrow(Known);

    state.view = .{
        .frame = &state.row,
        .parents = target.parents,
        .known = &state.known,
    };
}

fn appendFrame(target: *Target) std.mem.Allocator.Error!void {
    const state = target.walk;

    try state.stack.append(state.frames, .{ .snapshot = target.pending });

    state.bind();
}

fn alignFields(state: *Walk, existing_names: ?[]const []const u8, existing_values: []const u32, incoming_values: []const u32, closed: bool) std.mem.Allocator.Error!void {
    const existing = existing_names orelse Graph.Fields.viewFromValues(@ptrCast(existing_values)).names();
    const incoming = Graph.Fields.viewFromValues(@ptrCast(incoming_values)).names();

    state.current().fields = try Fields.alignFields(state.fields, existing, incoming, closed);
    state.bind();
}

fn popFrame(state: *Walk) void {
    const frame = state.stack.pop().?;

    state.fields.free(frame.fields.positions);

    if (state.stack.items.len != 0) state.bind();
}

fn publishFields(target: *Target) std.mem.Allocator.Error![]const u32 {
    const frame = target.walk.current();
    const left = target.graph.mutableFields(frame.snapshot.left_members);
    const right = Graph.Fields.viewFromValues(@ptrCast(frame.snapshot.right_members));
    const published = try Fields.publish(&target.graph.field_buffers, target.graph.allocator, left, right, frame.fields);

    return @ptrCast(published.values());
}

fn commitFrame(target: *Target, effect: anytype) zx.Error!void {
    try Commit.publish(
        target.graph,
        @fromBackingInt(effect.parent.?),
        @fromBackingInt(effect.child.?),
        .{ .allowed = effect.first_allowed, .fallback = effect.first_fallback },
        .{ .allowed = effect.second_allowed, .fallback = effect.second_fallback },
        .{ .kind = @fromBackingInt(@intCast(effect.kind.?)), .argument = effect.argument.?, .members = effect.members.? },
        target.span,
    );
}

fn internType(target: *Target, type_id: u32) zx.Error!u32 {
    const result = try target.graph.known(@fromBackingInt(type_id), target.span);

    target.bind();

    target.walk.view.parents = target.parents;
    target.walk.known = target.graph.pending.known_types.borrow(Known);

    return @backingInt(result);
}
