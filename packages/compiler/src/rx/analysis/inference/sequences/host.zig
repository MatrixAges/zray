const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Sequences = @import("../sequences.zig");
const Registration = @import("../assignment/registration.zig");
const Target = @import("target.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_replay_sequences");
const Input = std.meta.Child(entry.Input);
const View = std.meta.Child(@FieldType(Input, "graph"));
const Rows = std.MultiArrayList(Sequences.Sequence).Slice;

const Frame = struct {
    graph: *Graph,
    rows: Rows,
    view: View = undefined,
    parents: []u32 = undefined,
    fn bind(self: *Frame) void {
        self.view = Target.borrow(View, self.graph);
        self.parents = self.graph.parents();
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, rows: Rows) zx.Error!void {
    if (rows.len == 0) return;

    var frame: Frame = .{ .graph = graph, .rows = rows };

    frame.bind();

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .graph = &frame.view,
        .parents = @ptrCast(&frame.parents),
        .values = @ptrCast(rows.items(.value)),
        .elements = @ptrCast(rows.items(.elements)),
    };

    entry.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn expectSequenceList(handle: *const anyopaque, row: u64, child: u32, declared: bool) zx.Error!void {
    const frame = Frame.borrow(handle);

    try Sequences.expectList(frame.graph, frame.rows.get(@intCast(row)), child, declared);

    frame.bind();
}

pub fn expectSequenceTuple(handle: *const anyopaque, row: u64, members: []const u32, declared: bool) zx.Error!void {
    const frame = Frame.borrow(handle);
    const sequence = frame.rows.get(@intCast(row));
    const targets: Registration.Targets = if (declared) .{ .declared = members } else .{ .inferred = members };

    try Registration.expectMany(frame.graph, sequence.elements, sequence.spans, targets);

    frame.bind();
}

pub fn rejectSequenceReplay(handle: *const anyopaque, row: u64, length: bool) zx.Error!void {
    const frame = Frame.borrow(handle);
    const span = frame.rows.items(.span)[@intCast(row)];

    return if (length) Sequences.lengthMismatch(frame.graph, span) else Sequences.invalidSequence(frame.graph, span);
}
