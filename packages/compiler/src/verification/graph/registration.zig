const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const execution = @import("../execution/context.zig");
const workflow = @import("generated_bind_symbolic_definition");

const Frame = struct {
    graph: *Graph,
    expression: []const u8,
    origin: Graph.Origin,
    width: u16,
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn bind(graph: *Graph, expression: []const u8, width: u16, origin: Graph.Origin) zx.Error![]const u8 {
    var frame: Frame = .{
        .graph = graph,
        .expression = expression,
        .width = width,
        .origin = origin,
    };

    const rows = graph.definitions.slice();

    const input: std.meta.Child(workflow.Input) = .{
        .graph = @ptrCast(&frame),
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

    return workflow.executeIn(graph.allocator, &input) catch |err| return execution.failure(err);
}

pub fn reserveSymbolicDefinition(handle: *anyopaque) std.mem.Allocator.Error!void {
    const graph = Frame.borrow(handle).graph;

    try graph.definitions.ensureUnusedCapacity(graph.allocator, 1);
}

pub fn commitSymbolicDefinition(handle: *anyopaque, name: []const u8, file: []const u8, resized: bool, buckets: []const u64, slot: u64, value: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const owned_buckets = if (resized) try graph.allocator.dupe(u64, buckets) else null;

    graph.appendDefinition(.{
        .name = name,
        .expression = frame.expression,
        .width = frame.width,
        .origin = .{ .file_name = file, .span = frame.origin.span },
    });

    if (owned_buckets) |next| {
        graph.allocator.free(graph.index);

        graph.index = next;
    } else {
        graph.index[@intCast(slot)] = value;
    }
}

pub fn rejectSymbolicDefinition(handle: *anyopaque, message: ?[]const u8) error{InvalidSource}![]const u8 {
    const frame = Frame.borrow(handle);

    if (message) |text| {
        return @errorCast(frame.graph.reporter.fail(.unsupported, frame.origin.span, text));
    }

    return error.InvalidSource;
}
