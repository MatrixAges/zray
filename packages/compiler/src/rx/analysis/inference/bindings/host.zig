const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Bindings = @import("../bindings.zig");
const rules = @import("rules.zig");
const errors = @import("../../project/workflow/errors.zig");
const entry = @import("generated_rx_replay_bindings");
const Input = std.meta.Child(entry.Input);
const Topology = std.meta.Child(@FieldType(Input, "topology"));
const View = std.meta.Child(@FieldType(Topology, "graph"));
const Collisions = std.MultiArrayList(Bindings.Collision).Slice;
const Lookups = std.MultiArrayList(Bindings.Lookup).Slice;

const Frame = struct {
    graph: *Graph,
    collisions: Collisions,
    lookups: Lookups,
    view: View = undefined,
    parents: []u32 = undefined,
    fn bind(self: *Frame) void {
        self.view = rules.view(entry, self.graph);
        self.parents = self.graph.parents();
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, final: bool) zx.Error!void {
    const collisions = graph.pending.binding_collisions.slice();
    const lookups = graph.pending.binding_lookups.slice();

    if (collisions.len == 0 and lookups.len == 0) return;

    var frame: Frame = .{ .graph = graph, .collisions = collisions, .lookups = lookups };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .topology = &.{ .graph = &frame.view, .parents = @ptrCast(&frame.parents) },
        .collisions = &.{ .left = @ptrCast(collisions.items(.left)), .right = @ptrCast(collisions.items(.right)), .final = final },
        .candidates = @ptrCast(lookups.items(.candidates)),
        .values = @ptrCast(lookups.items(.value)),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn unifyBindingReplay(handle: *const anyopaque, index: u64, value: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const row = frame.lookups.get(@intCast(index));

    try frame.graph.unify(row.value, @fromBackingInt(value), row.span);

    frame.bind();
}

pub fn rejectBindingReplay(handle: *const anyopaque, index: u64, collision: bool) zx.Error!void {
    const frame = Frame.borrow(handle);
    const row: usize = @intCast(index);

    if (collision) {
        const pair = frame.collisions.get(row);

        return frame.graph.reporter.fail(.name, pair.span, pair.message);
    }

    return frame.graph.reporter.fail(.name, frame.lookups.items(.span)[row], Bindings.missing_message);
}
