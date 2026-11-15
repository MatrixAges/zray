const std = @import("std");
const Shape = @import("../flow.zig");
const Plan = @import("plan.zig");
const Counts = Plan.Counts;
const Error = @import("../builder.zig").Error;
const Exit = enum(u32) { Continue, Return, Unreachable };

pub fn plan(shape: *const Shape, rows: []Plan.Row, blocks: Plan.Blocks, capture_count: usize, void_output: bool) Error!Plan {
    for (rows, shape.units.items(.first), shape.units.items(.count)) |*row, first, count| {
        row.* = try summarize(shape, rows, first, count);
    }

    const exit: Exit = @fromBackingInt(@intCast(rows[rows.len - 1].tag));

    if (exit == .Unreachable) return error.UnreachableFlow;
    if (exit == .Continue and !void_output) return error.IncompleteFlow;

    var size: Counts = .{};
    var block_index: u32 = 0;
    var inline_start: ?usize = null;
    const kinds = shape.units.items(.block);

    for (rows, kinds, 0..) |*row, block, unit| {
        if (block) {
            const next = try size.plus(row.first);

            if (inline_start) |start| {
                rows[start].tag = @intCast(unit);
                inline_start = null;
            }

            blocks.firsts[block_index] = std.math.cast(u32, size.statements()) orelse return error.OutOfMemory;
            blocks.counts[block_index] = std.math.cast(u32, row.first.statements()) orelse return error.OutOfMemory;
            row.* = .{ .first = size, .tag = block_index };
            size = next;
            block_index += 1;
        } else if (inline_start == null) inline_start = unit;
    }

    size = try size.plus(.{
        .constants = std.math.cast(u32, capture_count) orelse return error.OutOfMemory,
        .results = @intFromBool(exit == .Continue),
    });

    if (size.statements() > std.math.maxInt(u32)) return error.OutOfMemory;

    const last = block_index - 1;

    blocks.counts[last] = @intCast(size.statements() - blocks.firsts[last]);

    return .{ .rows = rows, .blocks = kinds, .size = size, .implicit_return = exit == .Continue };
}

fn summarize(shape: *const Shape, rows: []const Plan.Row, first: u32, count: u32) Error!Plan.Row {
    var exit: Exit = .Continue;
    var size: Counts = .{};

    for (first..@as(usize, first) + count) |index| {
        if (exit != .Continue) {
            exit = .Unreachable;

            break;
        }

        const step = shape.steps.get(index);
        var publication = step.output;

        switch (step.kind) {
            .Call => {
                const call = shape.calls.get(step.first);

                size = try size.plus(.{ .constants = call.getters });
                publication = if (call.publishes) .Constant else .Evaluate;
            },
            .Parallel => {
                size = try size.plus(.{ .parallels = 1, .invocations = step.count });

                for (shape.calls.items(.getters)[step.first..][0..step.count]) |getters| {
                    size = try size.plus(.{ .constants = getters });
                }
            },
            .Return => {
                size = try size.plus(.{ .results = 1 });
                exit = .Return;
            },
            .Task => {
                const child = rows[step.first];
                const end: Exit = @fromBackingInt(@intCast(child.tag));

                size = try size.plus(child.first);

                if (step.output == .None or end == .Unreachable) exit = end;
            },
            .Selection => {
                size = try size.plus(.{ .selections = 1, .cases = step.count });
                exit = if (step.exhaustive) .Return else .Continue;

                for (shape.cases.items(.body)[step.first..][0..step.count]) |id| {
                    const end: Exit = @fromBackingInt(@intCast(rows[id].tag));

                    if (end == .Unreachable) {
                        exit = end;

                        break;
                    }

                    if (end == .Continue) exit = end;
                }
            },
        }

        size = try size.plus(.{
            .evaluations = @intFromBool(publication == .Evaluate),
            .constants = @intFromBool(publication == .Constant),
        });
    }

    return .{ .first = size, .tag = @backingInt(exit) };
}
