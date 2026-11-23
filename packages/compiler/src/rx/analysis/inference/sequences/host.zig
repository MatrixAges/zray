const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Registration = @import("../assignment/registration.zig");
const solver = @import("generated_rx_run_constraint_solver");
const Input = std.meta.Child(solver.Input);
const View = std.meta.Child(@FieldType(Input, "sequences"));
const Spans = @FieldType(View, "spans");

pub fn borrowSequenceElementSpans(handle: *const anyopaque, row: u64) Spans {
    const graph: *const Graph = @ptrCast(@alignCast(handle));

    return @ptrCast(&graph.pending.sequences.items(.spans)[@intCast(row)]);
}

pub fn expectSequenceMembers(handle: *const anyopaque, row: u64, members: []const u32, repeated: ?u32, declared: bool) zx.Error!void {
    const graph: *Graph = @ptrCast(@alignCast(@constCast(handle)));
    const sequence = graph.pending.sequences.get(@intCast(row));

    const targets: Registration.Targets = if (repeated) |child|
        .{ .repeated = @fromBackingInt(child) }

    else if (declared)
        .{ .declared = members }
    else
        .{ .inferred = members };

    try Registration.expectMany(graph, sequence.elements, sequence.spans, targets);
}
