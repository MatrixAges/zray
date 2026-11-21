const std = @import("std");
const zx = @import("zx");
const Function = @import("../../function.zig");
const Growth = @import("../../growth.zig");
const Summaries = @import("../../summaries.zig");
const Origin = @import("select.zig").Origin;
const Level = @import("../../level.zig").Level;
const rowInput = @import("../../retain.zig").rowInput;

pub fn apply(allocator: std.mem.Allocator, owner: std.mem.Allocator, summaries: *Summaries, target: *Growth.Store, rows: Growth.Rows, marks: []const Function.Mark, comptime origin: Origin, grew: bool) std.mem.Allocator.Error![]const u64 {
    const entry = @import("generated_uniqueness_visit_demand");
    const Input = std.meta.Child(entry.Input);
    const Binding = std.meta.Child(@FieldType(Input, "growth"));
    const Snapshot = std.meta.Child(@typeInfo(@FieldType(Binding, "snapshot")).optional.child);
    const Retention = std.meta.Child(@FieldType(Snapshot, "rows"));
    var normalized = zx.memory.RowBuffer.empty(Growth.Normalized);
    var renewed = zx.memory.RowBuffer.empty(Growth.Renewed);
    const output_rows: []Growth.Rows = @as(*[1]Growth.Rows, @ptrCast(target));
    const result_normalized = zx.memory.borrowWriteColumn([]const Growth.Normalized, "normalized", output_rows);
    const result_renewed = zx.memory.borrowWriteColumn([]const Growth.Renewed, "renewed", output_rows);

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
        .growth = &.{
            .target = @ptrCast(&column),
            .rows = std.mem.asBytes(&rows),
            .snapshot = if (origin == .Ahead) &.{
                .grew = grew,
                .rows = &.{
                    .normalized = &rowInput(std.meta.Child(@FieldType(Retention, "normalized")), &normalized, rows.normalized, &owner),
                    .renewed = &rowInput(std.meta.Child(@FieldType(Retention, "renewed")), &renewed, rows.renewed, &owner),
                },
                .normalized = @ptrCast(&result_normalized),
                .renewed = @ptrCast(&result_renewed),
            } else null,
        },
    };

    return zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("demand visitation failed: {s}", .{@errorName(err)}),
    };
}
