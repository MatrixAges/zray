const std = @import("std");
const zx = @import("zx");
const Function = @import("../../function.zig");
const Growth = @import("../../growth.zig");
const Summaries = @import("../../summaries.zig");
const Origin = @import("select.zig").Origin;
const Level = @import("../../level.zig").Level;

pub fn apply(allocator: std.mem.Allocator, summaries: *Summaries, target: *Growth.Store, rows: Growth.Rows, marks: []const Function.Mark, origin: Origin) std.mem.Allocator.Error![]const u64 {
    if (!@import("genz_options").generated_analysis) {
        if (origin == .Ahead) try Growth.restore(target, rows);

        const changed = try Function.replayMarksSeed(allocator, summaries, marks);

        if (origin == .Cached) try Growth.restore(target, rows);

        return changed;
    }

    const entry = @import("generated_uniqueness_visit_demand");
    const Input = std.meta.Child(entry.Input);

    const column: zx.memory.WriteColumn = .{
        .items = @ptrCast(target),
        .count = 1,
        .stride = @sizeOf(Growth.Rows),
        .width = @sizeOf(Growth.Rows),
    };

    const output = zx.memory.borrowReadColumn(bool, "output", marks);
    const functions = zx.memory.borrowReadColumn(u32, "function", marks);
    const slots = zx.memory.borrowReadColumn(u32, "slot", marks);
    const wants = zx.memory.borrowReadColumn(Level, "want", marks);

    const input: Input = .{
        .inputs = @ptrCast(&summaries.inputs),
        .outputs = @ptrCast(&summaries.outputs),
        .marks = &.{
            .output = @ptrCast(&output),
            .functions = @ptrCast(&functions),
            .slots = @ptrCast(&slots),
            .wants = @ptrCast(&wants),
            .count = marks.len,
        },
        .origin = origin,
        .growth = &.{ .target = @ptrCast(&column), .rows = std.mem.asBytes(&rows) },
    };

    return zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("demand visitation failed: {s}", .{@errorName(err)}),
    };
}
