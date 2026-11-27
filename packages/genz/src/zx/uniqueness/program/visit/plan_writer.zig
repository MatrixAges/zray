const std = @import("std");
const analysis = @import("../../root.zig");
const Plan = analysis.Plan;
const generated = @import("genz_options").generated_analysis;
const Self = @This();
const empty: Plan = .{ .flags = &.{} };

rows: []Plan,
entry: Plan = empty,
pub fn init(allocator: std.mem.Allocator, active: []const bool) std.mem.Allocator.Error!Self {
    return .{ .rows = try allocate(allocator, active) };
}

fn allocate(allocator: std.mem.Allocator, active: []const bool) std.mem.Allocator.Error![]Plan {
    if (!generated) {
        const rows = try allocator.alloc(Plan, active.len - 1);

        @memset(rows, empty);

        return rows;
    }

    const rule = @import("generated_uniqueness_visit_initialize");
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const plan = rule.executeValue(scratch.allocator(), active) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const rows = try allocator.alloc(Plan, @intCast(plan.count));

    for (rows, plan.initialize[0..rows.len]) |*row, initialize| {
        if (initialize) row.* = empty;
    }

    return rows;
}

pub fn target(self: *Self) @import("../../work/round.zig").PlanTarget {
    return .{ .functions = self.rows, .entry = &self.entry };
}

pub fn putSeed(self: *Self, index: usize, value: Plan) void {
    if (index == self.rows.len) self.entry = value else self.rows[index] = value;
}

pub fn result(self: *const Self) analysis.Result {
    return .{ .functions = self.rows, .entry = self.entry };
}
