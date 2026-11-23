const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const Conditions = @import("../conditions.zig");
const execution = @import("../execution/context.zig");
const rule = @import("generated_assemble_symbolic_query");
const Allocator = std.mem.Allocator;

const Frame = struct {
    graph: *Graph,
    allocator: Allocator,
    output: std.Io.Writer.Allocating,
    correctness: ?[]u8 = null,
    feasibility: []u8 = undefined,
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn write(result: Allocator, graph: *Graph, precondition_count: usize, sections: anytype, inputs: []const Conditions.Input) zx.Error!Conditions.Query {
    const capacity = sections.header.len +| graph.declarationCapacity() +| sections.correctness.len;

    var frame: Frame = .{
        .graph = graph,
        .allocator = result,
        .output = try .initCapacity(result, capacity),
    };

    defer frame.output.deinit();
    errdefer if (frame.correctness) |bytes| result.free(bytes);

    const written: zx.memory.ColumnLengths = &.{&frame.output.writer.end};

    const input: std.meta.Child(rule.Input) = .{
        .query = @ptrCast(&frame),
        .writer = @ptrCast(&frame.output.writer),
        .written = @ptrCast(&written),
        .header = sections.header,
        .correctness = sections.correctness,
        .feasibility = sections.feasibility,
        .precondition_count = precondition_count,
        .definition_count = graph.definitions.len,
    };

    rule.executeIn(result, &input) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => execution.failure(err),
    };

    return .{ .feasibility = frame.feasibility, .correctness = frame.correctness.?, .inputs = inputs };
}

pub fn appendQueryDefinitions(handle: *const anyopaque, first: u64, end: u64) zx.Error!void {
    const frame = Frame.borrow(handle);

    try frame.graph.writeDeclarations(&frame.output.writer, @intCast(first), @intCast(end));
}

pub fn publishCorrectnessQuery(handle: *const anyopaque) Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.correctness = try frame.output.toOwnedSlice();
}

pub fn publishFeasibilityQuery(handle: *const anyopaque, prefix: u64, suffix: []const u8) Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const shared = frame.correctness.?[0..@intCast(prefix)];

    frame.feasibility = try std.mem.concat(frame.allocator, u8, &.{ shared, suffix });
}
