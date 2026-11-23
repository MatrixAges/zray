const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Kind = @import("../nodes.zig").Kind;
const Length = @import("../projections.zig").Length;
const Access = @import("../fields/access.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_replay_lengths");
const Input = std.meta.Child(entry.Input);
const Types = std.meta.Child(@FieldType(Input, "types"));
const Known = std.meta.Child(@FieldType(Input, "known"));
const Rows = std.MultiArrayList(Length).Slice;

const Frame = struct {
    graph: *Graph,
    rows: Rows,
    types: Types = undefined,
    known: Known = undefined,
    parents: []u32 = undefined,
    input: Input = undefined,
    fn bind(self: *Frame) void {
        const graph = self.graph;
        const nodes = graph.nodes.slice();
        const kinds: []const Kind = nodes.items(.kind);
        const types = &graph.types.items;

        self.types = .{
            .kinds = types.kinds.items,
            .first = types.first.items,
            .second = types.second.items,
            .field_names = types.field_names.items,
            .field_types = types.field_types.items,
        };

        self.parents = graph.parents();
        self.known = graph.pending.known_types.borrow(Known);
        self.input.kinds = zx.columns.slice(@FieldType(Input, "kinds"), kinds);
        self.input.arguments = nodes.items(.argument);
        self.input.allowed = nodes.items(.allowed);
    }

    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn unify(self: *Frame, row: Length, value: Graph.Id) zx.Error!void {
        try self.graph.unify(value, row.value, row.span);

        self.bind();
    }
};

pub fn run(graph: *Graph, rows: Rows) zx.Error!void {
    if (rows.len == 0) return;

    var frame: Frame = .{ .graph = graph, .rows = rows };

    frame.input = .{
        .frame = @ptrCast(&frame),
        .kinds = undefined,
        .arguments = undefined,
        .allowed = undefined,
        .types = &frame.types,
        .parents = @ptrCast(&frame.parents),
        .known = &frame.known,
        .targets = @ptrCast(rows.items(.target)),
        .values = @ptrCast(rows.items(.value)),
    };

    frame.bind();

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(empty.allocator(), &frame.input) catch |err| return errors.errorSet(err);
}

pub fn unifyLengthReplay(handle: *const anyopaque, index: u64, value: u32, register: bool) zx.Error!void {
    const frame = Frame.borrow(handle);
    const row = frame.rows.get(@intCast(index));
    const node: Graph.Id = if (register) try frame.graph.known(@fromBackingInt(value), row.span) else @fromBackingInt(value);

    try frame.unify(row, node);
}

pub fn requireListLength(handle: *const anyopaque, index: u64) zx.Error!void {
    const frame = Frame.borrow(handle);
    const row = frame.rows.get(@intCast(index));

    _ = try frame.graph.payload(row.target, .list, row.span);

    try frame.unify(row, try frame.graph.scalar(.u64, row.span));
}

pub fn unifyOpenLength(handle: *const anyopaque, index: u64, root: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const row = frame.rows.get(@intCast(index));
    const field = try Access.open(frame.graph, @fromBackingInt(root), Access.length_name, row.span);

    try frame.unify(row, field);
}

pub fn rejectLengthReplay(handle: *const anyopaque, index: u64, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frame.graph.reporter.fail(.type_mismatch, frame.rows.items(.span)[@intCast(index)], message);
}
