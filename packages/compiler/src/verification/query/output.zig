const std = @import("std");
const Graph = @import("../graph.zig");
const Conditions = @import("../conditions.zig");
const Allocator = std.mem.Allocator;
const layout = @import("generated_verification_query");

pub const Sections = struct {
    declarations: []const []const u8,
    violations: []const []const u8,
    precondition: []const u8,
};

pub fn render(result: Allocator, temporary: Allocator, graph: *Graph, precondition_count: usize, input: Sections, inputs: []const Conditions.Input) zx.Error!Conditions.Query {
    var scratch = std.heap.ArenaAllocator.init(temporary);

    defer scratch.deinit();

    const rows = graph.definitions.slice();

    const request: std.meta.Child(layout.Input) = .{
        .declarations = input.declarations,
        .precondition = input.precondition,
        .violations = input.violations,
        .names = rows.items(.name),
        .expressions = rows.items(.expression),
        .widths = rows.items(.width),
        .precondition_count = precondition_count,
    };

    const assembled = layout.executeIn(scratch.allocator(), &request) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };

    const feasibility = try result.dupe(u8, assembled.feasibility);

    errdefer result.free(feasibility);

    const correctness = try result.dupe(u8, assembled.correctness);

    return .{ .feasibility = feasibility, .correctness = correctness, .inputs = inputs };
}

const zx = @import("zx");
