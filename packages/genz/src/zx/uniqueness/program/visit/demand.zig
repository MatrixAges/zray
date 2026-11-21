const std = @import("std");
const zx = @import("zx");
const Function = @import("../../function.zig");
const Growth = @import("../../growth.zig");
const Summaries = @import("../../summaries.zig");
const Origin = @import("select.zig").Origin;
const Level = @import("../../level.zig").Level;
const rowInput = @import("../../retain.zig").rowInput;
const rows = @import("../../row_output.zig");
const Memo = @import("../../memo.zig");
const record = @import("../../memo/record.zig");

pub const Adopted = struct { changed: []const u64, stored: ?Memo.Demanded };

pub fn apply(allocator: std.mem.Allocator, owner: std.mem.Allocator, summaries: *Summaries, target: *Growth.Store, growth: Growth.Rows, marks: []const Function.Mark, comptime origin: Origin, grew: bool, memo: ?*Memo) std.mem.Allocator.Error!Adopted {
    const entry = @import("generated_uniqueness_visit_demand");
    const Input = std.meta.Child(entry.Input);
    const Binding = std.meta.Child(@FieldType(Input, "growth"));
    const Snapshot = std.meta.Child(@typeInfo(@FieldType(Binding, "snapshot")).optional.child);
    const Retention = std.meta.Child(@FieldType(Snapshot, "rows"));
    const Save = rows.Target(Input, "save");
    var retained_marks = zx.memory.RowBuffer.empty(Function.Mark);
    var scope = zx.memory.ArenaScope{ .active = allocator };
    var stored: record.Frame(.demanded, rows.Target(Save, "memo")) = undefined;
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

    if (memo) |cache| stored.open(cache, &scope, &allocator, .{ .marks = &retained_marks, .growth = target });

    defer if (memo != null) stored.table.finish();

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
            .rows = std.mem.asBytes(&growth),
            .snapshot = if (origin == .Ahead) &.{
                .grew = grew,
                .rows = &.{
                    .normalized = &rowInput(std.meta.Child(@FieldType(Retention, "normalized")), &normalized, growth.normalized, &owner),
                    .renewed = &rowInput(std.meta.Child(@FieldType(Retention, "renewed")), &renewed, growth.renewed, &owner),
                },
                .normalized = @ptrCast(&result_normalized),
                .renewed = @ptrCast(&result_renewed),
            } else null,
        },
        .save = if (memo != null) &.{
            .memo = &stored.target,
            .marks = &rowInput(rows.Target(Save, "marks"), &retained_marks, marks, &owner),
            .grew = grew,
        } else null,
    };

    const changed = zx.columns.invoke(entry.executeValue, scope.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("demand visitation failed: {s}", .{@errorName(err)}),
    };

    return .{ .changed = changed, .stored = if (memo != null) stored.value else null };
}
