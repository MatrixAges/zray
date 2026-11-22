const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const execution = @import("../execution/context.zig");
const workflow = @import("generated_bind_symbolic_definition");
const publication = @import("generated_verification_graph_publish");

const Frame = struct {
    graph: *Graph,
    expression: []const u8,
    origin: Graph.Origin,
    width: u16,
    staged: ?[]u64 = null,
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn bind(graph: *Graph, expression: []const u8, width: u16, origin: Graph.Origin) zx.Error![]const u8 {
    var frame: Frame = .{ .graph = graph, .expression = expression, .width = width, .origin = origin };

    defer if (frame.staged) |buckets| graph.allocator.free(buckets);

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
        .names = rows.items(.name),
    };

    return workflow.executeIn(graph.allocator, &input) catch |err| return execution.failure(err);
}

pub fn reserveSymbolicDefinition(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const graph = Frame.borrow(handle).graph;

    try graph.definitions.ensureUnusedCapacity(graph.allocator, 1);
}

pub fn allocateSymbolicIndex(handle: *const anyopaque, capacity: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const buckets = try frame.graph.allocator.alloc(u64, @intCast(capacity));

    @memset(buckets, 0);

    frame.staged = buckets;
}

pub fn writeSymbolicDefinition(handle: *const anyopaque, position: u64, resized: bool) std.mem.Allocator.Error![]const u8 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const rows = graph.definitions.slice();
    const buckets = frame.staged orelse graph.index;

    const request: std.meta.Child(publication.Input) = .{
        .origin = &.{
            .count = rows.len,
            .file = frame.origin.file_name,
            .previous = if (rows.len == 0) null else rows.items(.origin)[rows.len - 1].file_name,
        },
        .index = &.{
            .keys = rows.items(.expression),
            .key = frame.expression,
            .buckets = @ptrCast(&buckets),
            .capacity = buckets.len,
            .position = position,
            .resized = resized,
        },
    };

    const identity = zx.columns.invoke(publication.executeValue, graph.allocator, &request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    graph.appendDefinition(.{
        .name = identity.name,
        .expression = frame.expression,
        .width = frame.width,
        .origin = .{ .file_name = identity.file, .span = frame.origin.span },
    });

    return identity.name;
}

pub fn installSymbolicIndex(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;

    graph.allocator.free(graph.index);

    graph.index = frame.staged.?;
    frame.staged = null;
}

pub fn rejectSymbolicDefinition(handle: *const anyopaque, message: ?[]const u8) error{InvalidSource}![]const u8 {
    const frame = Frame.borrow(handle);

    if (message) |text| {
        return @errorCast(frame.graph.reporter.fail(.unsupported, frame.origin.span, text));
    }

    return error.InvalidSource;
}
