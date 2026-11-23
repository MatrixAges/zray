const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const View = @import("../fields/view.zig");
const Selection = @import("../selection.zig").Selection;
const generated = @import("generated_object_selection_project");

pub fn apply(graph: *Graph, value: Selection, root: Graph.Id, final: bool) zx.Error!void {
    const source = View.read(graph, root);
    const declared = source.mode == .Declared;

    if (!declared and source.mode != .Inferred) return graph.reporter.fail(.type_mismatch, value.span, "object selection requires an object source");
    // Register all declared member types before applying the projection, in source order.
    if (declared) try @import("../known.zig").registerMembers(graph, source.values, value.span);

    var arena = std.heap.ArenaAllocator.init(graph.scratch);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const allocator = scratch.allocator();
    const names = source.names;

    const plan = generated.executeValue(allocator, &.{
        .fields = &.{ .names = names, .first = 0, .count = names.len, .keys = value.keys, .omit = value.omit },
        .mode = @fromBackingInt(@backingInt(source.mode)),
        .final = final,
    }) catch |err| return failure(err);

    switch (plan.status) {
        .Missing => return graph.reporter.fail(.name, value.span, "unknown object selection field"),
        .Wait => return,
        .Ready => {},
    }

    return @import("application/host.zig").run(graph, value, source, plan.indices, plan.all, final, allocator);
}

fn failure(err: anyerror) zx.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
