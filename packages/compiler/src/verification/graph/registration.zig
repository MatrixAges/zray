const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const execution = @import("../execution/context.zig");
const workflow = @import("generated_bind_symbolic_definition");

pub fn bind(graph: *Graph, expression: []const u8, width: u16, origin: Graph.Origin) zx.Error![]const u8 {
    const rows = graph.definitions.slice();

    const input: std.meta.Child(workflow.Input) = .{
        .expression = expression,
        .lookup = &.{
            .keys = rows.items(.expression),
            .key = expression,
            .widths = rows.items(.width),
            .width = width,
            .buckets = @ptrCast(&graph.index),
            .capacity = graph.index.len,
        },
        .origin = &.{
            .count = rows.len,
            .file = origin.file_name,
            .previous = if (rows.len == 0) null else rows.items(.origin)[rows.len - 1].file_name,
        },
        .names = rows.items(.name),
    };

    const plan = workflow.executeIn(graph.allocator, &input) catch |err| return execution.failure(err);

    if (plan.failure) |failure| {
        if (failure.message) |message| return graph.reporter.fail(.unsupported, origin.span, message);

        return error.InvalidSource;
    }

    if (plan.definition) |definition| {
        try graph.definitions.ensureUnusedCapacity(graph.allocator, 1);

        const owned_buckets = if (definition.resized) try graph.allocator.dupe(u64, definition.buckets) else null;

        graph.appendDefinition(.{
            .name = definition.name,
            .expression = expression,
            .width = width,
            .origin = .{ .file_name = definition.file, .span = origin.span },
        });

        if (owned_buckets) |next| {
            graph.allocator.free(graph.index);

            graph.index = next;
        } else {
            graph.index[@intCast(definition.slot)] = definition.value;
        }
    }

    return plan.name.?;
}
