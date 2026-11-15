const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const View = @import("../fields/view.zig");
const Fields = @import("../fields/replay.zig");
const Selection = @import("../selection.zig").Selection;
const generated = @import("generated_object_selection_project");
const covers = @import("generated_object_selection_covers");

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
        .required = final or declared,
    }) catch |err| return failure(err);

    switch (plan.status) {
        .Missing => return graph.reporter.fail(.name, value.span, "unknown object selection field"),
        .Wait => return,
        .Ready => {},
    }

    try unifyFields(graph, value, source, plan.indices, plan.all);

    if (!final) return;

    const result = View.read(graph, graph.root(value.result));

    switch (result.mode) {
        .Inferred, .Declared => {},
        .InvalidDeclared => return graph.reporter.fail(.type_mismatch, value.span, "object selection requires an object result"),
        else => return,
    }

    const valid = covers.executeValue(allocator, &.{
        .source = names,
        .result = result.names,
        .indices = plan.indices,
        .all = plan.all,
    }) catch |err| return failure(err);

    if (!valid) return graph.reporter.fail(.name, value.span, "field is outside the object selection result");
}

fn unifyFields(graph: *Graph, value: Selection, source: View, indices: []const u32, all: bool) zx.Error!void {
    const rule = @import("generated_object_selection_replay");
    const Input = std.meta.Child(rule.Input);
    const count = if (all) source.names.len else indices.len;
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var position: usize = 0;

    while (position < count) {
        const root = graph.root(value.result);
        const target = Fields.borrow(std.meta.Child(@FieldType(Input, "target")), graph, root);
        const known = graph.pending.known_types.borrow(std.meta.Child(@FieldType(Input, "known")));
        const parents = graph.parents();

        const input: Input = .{
            .names = source.names,
            .values = source.values,
            .declared = source.mode == .Declared,
            .indices = indices,
            .all = all,
            .target = &target,
            .parents = @ptrCast(&parents),
            .known = &known,
            .first = position,
        };

        const next = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        if (next.position == count) return;

        const name = source.names[@intCast(next.index)];
        const field = try Fields.field(graph, value.result, root, name, next.target, value.span);

        try graph.unify(field, @fromBackingInt(next.source.?), value.span);

        position = @intCast(next.position + 1);
    }
}

fn failure(err: anyerror) zx.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
