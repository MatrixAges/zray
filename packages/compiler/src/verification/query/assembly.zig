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
    output: ?std.Io.Writer.Allocating = null,
    correctness: ?[]u8 = null,
    feasibility: []u8 = undefined,
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn write(result: Allocator, graph: *Graph, precondition_count: usize, sections: anytype, inputs: []const Conditions.Input) zx.Error!Conditions.Query {
    var frame: Frame = .{ .graph = graph, .allocator = result };

    defer if (frame.output) |*writer| writer.deinit();
    errdefer if (frame.correctness) |bytes| result.free(bytes);

    const input: std.meta.Child(rule.Input) = .{
        .query = @ptrCast(&frame),
        .capacity = sections.header.len +| graph.declarationCapacity() +| sections.correctness.len,
        .header = sections.header,
        .correctness = sections.correctness,
        .feasibility = sections.feasibility,
        .precondition_count = precondition_count,
        .definition_count = graph.definitions.len,
    };

    rule.executeIn(result, &input) catch |err| return execution.failure(err);

    return .{ .feasibility = frame.feasibility, .correctness = frame.correctness.?, .inputs = inputs };
}

pub fn reserveQueryBuffer(handle: *const anyopaque, capacity: u64) Allocator.Error!void {
    const frame = Frame.borrow(handle);
    frame.output = try std.Io.Writer.Allocating.initCapacity(frame.allocator, @intCast(capacity));
}

pub fn appendQueryText(handle: *const anyopaque, text: []const u8) Allocator.Error!void {
    Frame.borrow(handle).output.?.writer.writeAll(text) catch return error.OutOfMemory;
}

pub fn appendQueryDefinitions(handle: *const anyopaque, first: u64, end: u64) zx.Error!void {
    const frame = Frame.borrow(handle);

    try frame.graph.writeDeclarations(&frame.output.?.writer, @intCast(first), @intCast(end));
}

pub fn queryWrittenLength(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).output.?.written().len;
}

pub fn publishCorrectnessQuery(handle: *const anyopaque) Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.correctness = try frame.output.?.toOwnedSlice();
}

pub fn publishFeasibilityQuery(handle: *const anyopaque, prefix: u64, suffix: []const u8) Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const shared = frame.correctness.?[0..@intCast(prefix)];

    frame.feasibility = try std.mem.concat(frame.allocator, u8, &.{ shared, suffix });
}
