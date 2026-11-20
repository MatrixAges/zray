const std = @import("std");
const zx = @import("zx");
const analysis = @import("../../root.zig");
const Plan = analysis.Plan;
const Self = @This();

rows: []Plan,
column: zx.memory.WriteColumn,

entry: Plan = .{ .flags = &.{} },
pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    const rows = try allocator.alloc(Plan, count);

    @memset(rows, .{ .flags = &.{} });

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

pub fn put(self: *Self, index: usize, value: Plan) void {
    if (!@import("genz_options").generated_analysis) {
        if (index == self.rows.len) self.entry = value else self.rows[index] = value;

        return;
    }

    const entry = @import("generated_uniqueness_visit_publish");

    const entry_column: zx.memory.WriteColumn = .{
        .items = @ptrCast(&self.entry),
        .count = 1,
        .stride = @sizeOf(Plan),
        .width = @sizeOf(Plan),
    };

    const input: std.meta.Child(entry.Input) = .{
        .plans = @ptrCast(&self.column),
        .entry = @ptrCast(&entry_column),
        .count = self.rows.len,
        .body = index,
        .fields = std.mem.asBytes(&value),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn result(self: *const Self) analysis.Result {
    return .{ .functions = self.rows, .entry = self.entry };
}
