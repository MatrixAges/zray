const std = @import("std");
const zx = @import("zx");
const Function = @import("../../function.zig");
const Growth = @import("../../growth.zig");
const Summaries = @import("../../summaries.zig");
const Level = @import("../../level.zig").Level;
const retention = @import("../../retain.zig");
const rows = @import("../../row_output.zig");
const Memo = @import("../../memo.zig");
const record = @import("../../memo/record.zig");
const publication = @import("../../memo/table/publication.zig");
const entry = @import("generated_uniqueness_visit_demand");
const Input = std.meta.Child(entry.Input);
const Origin = @FieldType(Input, "origin");
const Save = rows.Target(Input, "save");

pub const Adopted = struct { changed: []const u64, stored: ?Memo.Demanded };

pub fn apply(allocator: std.mem.Allocator, owner: std.mem.Allocator, summaries: *Summaries, target: *Growth.Store, growth: Growth.Rows, marks: []const Function.Mark, comptime origin: Origin, grew: bool, memo: ?*Memo) std.mem.Allocator.Error!Adopted {
    var stored: record.Frame(.demanded, rows.Target(Save, "memo")) = undefined;
    var host: publication.StoreHost(entry) = .{};
    const output = zx.memory.borrowReadColumn(bool, "output", marks);
    const functions = zx.memory.borrowReadColumn(u32, "function", marks);
    const slots = zx.memory.borrowReadColumn(u32, "slot", marks);
    const wants = zx.memory.borrowReadColumn(Level, "want", marks);

    if (memo) |cache| stored.open(cache);

    host.init(if (memo != null) stored.table.initial_used else 0, 0, false);

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
        .grew = grew,
        .save = if (memo != null) &.{
            .memo = &stored.target,
            .marks = &retention.rowInput(rows.Target(Save, "marks"), marks),
        } else null,
    };

    const result = entry.executeIn(allocator, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("demand visitation failed: {s}", .{@errorName(err)}),
    };

    if (result.retain_growth) {
        const normalized = try owner.dupe(Growth.Normalized, growth.normalized);

        errdefer owner.free(normalized);

        target.* = .{
            .normalized = normalized,
            .renewed = try owner.dupe(Growth.Renewed, growth.renewed),
        };
    } else if (result.install_growth) {
        target.* = growth;
    }

    if (result.marks) |retained| {
        stored.value = .{
            .marks = try retention.copyRows(Function.Mark, owner, retained),
            .normalized = target.normalized,
            .renewed = target.renewed,
            .grew = grew,
        };

        try stored.table.finish(host.state.*);
    }

    return .{ .changed = result.changed, .stored = if (memo != null) stored.value else null };
}
