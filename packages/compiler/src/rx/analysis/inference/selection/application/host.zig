const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const View = @import("../../fields/view.zig");
const Fields = @import("../../fields/replay.zig");
const Selection = @import("../../selection.zig").Selection;
const workflow = @import("../../../project/workflow/errors.zig");

pub fn run(graph: *Graph, value: Selection, source: View, indices: []const u32, all: bool, final: bool, allocator: std.mem.Allocator) zx.Error!void {
    const count = if (all) source.names.len else indices.len;

    if (count == 0 and !final) return;

    var fields: Fields.Frame = .{ .graph = graph, .result = value.result, .span = value.span };

    fields.bind();

    const rule = @import("generated_rx_apply_selected_fields");

    const input: std.meta.Child(rule.Input) = .{
        .frame = @ptrCast(&fields),
        .field_view = &fields.view,
        .source = &.{ .names = source.names, .values = source.values, .declared = source.mode == .Declared, .indices = indices, .all = all },
        .count = count,
        .final = final,
    };

    rule.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return workflow.errorSet(err),
    };
}

pub fn unifySelectedObjectField(handle: *const anyopaque, target: u32, source: ?u32) zx.Error!void {
    const frame = Fields.Frame.from(handle);

    try frame.graph.unify(@fromBackingInt(target), @fromBackingInt(source.?), frame.span);

    frame.bind();
}

pub fn rejectSelectedObjectResult(handle: *const anyopaque, invalid_type: bool) zx.Error!void {
    const frame = Fields.Frame.from(handle);
    const reporter = frame.graph.reporter;

    if (invalid_type) return reporter.fail(.type_mismatch, frame.span, "object selection requires an object result");

    return reporter.fail(.name, frame.span, "field is outside the object selection result");
}
