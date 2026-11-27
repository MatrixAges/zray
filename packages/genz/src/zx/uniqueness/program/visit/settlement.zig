const std = @import("std");
const Memo = @import("../../memo.zig");
const Summaries = @import("../../summaries.zig");
const rows = @import("../../row_output.zig");
const record = @import("../../memo/record.zig");
const publication = @import("../../memo/table/publication.zig");
const entry = @import("generated_uniqueness_visit_settlement");
const Input = std.meta.Child(entry.Input);
const Save = rows.Target(Input, "save");

pub const Adopted = struct { changed: []const u64, stored: ?Memo.Settled };

pub fn apply(scratch: std.mem.Allocator, summaries: *Summaries, value: *const Memo.Settled, memo: ?*Memo) std.mem.Allocator.Error!Adopted {
    var stored: record.Frame(.settled, rows.Target(Save, "memo")) = undefined;
    var host: publication.StoreHost(entry) = .{};

    if (memo) |cache| stored.open(cache);

    host.init(if (memo != null) stored.table.initial_used else 0, 0, false);

    const source = rows.ContributionRows.init(value.passed);
    const contributions = source.view(rows.Target(Input, "contributions"));
    const retention_view = source.view(rows.Target(rows.Target(Save, "retain"), "source"));

    const input: Input = .{
        .inputs = @ptrCast(&summaries.input),
        .contributions = &contributions,
        .save = if (memo != null) &.{
            .memo = &stored.target,
            .retain = &.{
                .source = &retention_view,
                .output = @ptrCast(value.output),
            },
        } else null,
    };

    const result = entry.executeIn(scratch, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("settlement adoption failed: {s}", .{@errorName(err)}),
    };

    if (memo) |cache| {
        stored.value = try rows.settlement(cache.arena.allocator(), result.retained.?);

        try stored.table.finish(host.state.*);
    }

    return .{ .changed = result.changed, .stored = if (memo != null) stored.value else null };
}
