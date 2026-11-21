const std = @import("std");
const zx = @import("zx");
const analysis = @import("../../root.zig");
const Plan = analysis.Plan;
const generated = @import("genz_options").generated_analysis;
const Self = @This();
const empty: Plan = .{ .flags = &.{} };

rows: []Plan,
column: zx.memory.WriteColumn,

entry: Plan = empty,
pub fn init(allocator: std.mem.Allocator, active: []const bool) std.mem.Allocator.Error!Self {
    const rows = try allocate(allocator, active);

    return .{
        .rows = rows,
        .column = .{
            .items = @ptrCast(rows.ptr),
            .count = rows.len,
            .stride = @sizeOf(Plan),
            .width = @sizeOf(Plan),
        },
    };
}

fn allocate(allocator: std.mem.Allocator, active: []const bool) std.mem.Allocator.Error![]Plan {
    if (!generated) {
        const rows = try allocator.alloc(Plan, active.len - 1);

        @memset(rows, empty);

        return rows;
    }

    const rule = @import("generated_uniqueness_visit_initialize");
    var destination: zx.memory.RowBuffer = .empty(Plan);

    const input: std.meta.Child(rule.Input) = .{
        .destination = @ptrCast(&destination),
        .active = active,
        .empty = std.mem.asBytes(&empty),
    };

    zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return destination.rows(Plan);
}

pub fn target(self: *Self) @import("../../work/round.zig").PlanTarget {
    const entry_column: zx.memory.WriteColumn = .{
        .items = @ptrCast(&self.entry),
        .count = 1,
        .stride = @sizeOf(Plan),
        .width = @sizeOf(Plan),
    };

    return .{ .functions = self.column, .entry = entry_column };
}

pub fn putSeed(self: *Self, index: usize, value: Plan) void {
    if (index == self.rows.len) self.entry = value else self.rows[index] = value;
}

pub fn result(self: *const Self) analysis.Result {
    return .{ .functions = self.rows, .entry = self.entry };
}
