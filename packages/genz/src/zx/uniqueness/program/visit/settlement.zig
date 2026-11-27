const std = @import("std");
const zx = @import("zx");
const Memo = @import("../../memo.zig");
const Summaries = @import("../../summaries.zig");
const rows = @import("../../row_output.zig");
const record = @import("../../memo/record.zig");
const publication = @import("../../memo/table/publication.zig");
const entry = @import("generated_uniqueness_visit_settlement");
const Input = std.meta.Child(entry.Input);
const Save = rows.Target(Input, "save");
const Retain = rows.Target(Save, "retain");
pub const Adopted = struct { changed: []const u64, stored: ?Memo.Settled };

pub fn apply(scratch: std.mem.Allocator, summaries: *Summaries, value: *const Memo.Settled, memo: ?*Memo) std.mem.Allocator.Error!Adopted {
    var passed: rows.Contributions(Retain, "target") = undefined;
    var stored: record.Frame(.settled, rows.Target(Save, "memo")) = undefined;
    var host: publication.StoreHost(entry) = .{};
    const owner = if (memo) |cache| cache.arena.allocator() else undefined;

    if (memo) |cache| {
        passed.init();
        stored.open(cache, .{ .passed = &passed.buffer });
    }

    host.init(if (memo != null) stored.table.initial_used else 0, 0, false);
    defer if (memo != null) stored.table.finish(host.state.*);

    const source = rows.ContributionRows.init(value.passed);
    const contributions = source.view(rows.Target(Input, "contributions"));

    const input: Input = .{
        .inputs = @ptrCast(&summaries.input),
        .contributions = &contributions,
        .save = if (memo != null) &.{
            .memo = &stored.target,
            .retain = &.{
                .source = &contributions,
                .target = &.{ .storage = @ptrCast(&passed.buffer), .columns = &passed.view },
                .output = @ptrCast(value.output),
                .owner = @ptrCast(&owner),
            },
        } else null,
    };

    const changed = entry.executeIn(scratch, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("settlement adoption failed: {s}", .{@errorName(err)}),
    };

    return .{ .changed = changed, .stored = if (memo != null) stored.value else null };
}
