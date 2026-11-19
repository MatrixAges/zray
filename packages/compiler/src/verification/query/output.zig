const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const Conditions = @import("../conditions.zig");
const Allocator = std.mem.Allocator;
const layout = if (@import("parser_options").generated_parser) @import("generated_verification_query") else @import("seed.zig");
const Request = @typeInfo(@TypeOf(layout.executeValue)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Request) == .pointer) std.meta.Child(Request) else Request;

pub fn render(result: Allocator, temporary: Allocator, graph: *Graph, precondition_count: usize, input: Input, inputs: []const Conditions.Input) zx.Error!Conditions.Query {
    var scratch = std.heap.ArenaAllocator.init(temporary);

    defer scratch.deinit();

    const sections = try layout.executeValue(scratch.allocator(), if (Input == Request) input else &input);
    const capacity = sections.header.len +| graph.declarationCapacity() +| sections.correctness.len;
    var output = try std.Io.Writer.Allocating.initCapacity(result, capacity);

    defer output.deinit();
    output.writer.writeAll(sections.header) catch return error.OutOfMemory;

    try graph.writeDeclarations(&output.writer, 0, precondition_count);

    const feasibility_prefix = output.written().len;

    try graph.writeDeclarations(&output.writer, precondition_count, graph.definitions.len);

    output.writer.writeAll(sections.correctness) catch return error.OutOfMemory;

    const correctness = try output.toOwnedSlice();

    errdefer result.free(correctness);

    const feasibility = try std.mem.concat(result, u8, &.{ correctness[0..feasibility_prefix], sections.feasibility });

    return .{ .feasibility = feasibility, .correctness = correctness, .inputs = inputs };
}
