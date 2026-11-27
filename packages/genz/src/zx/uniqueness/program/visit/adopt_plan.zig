const std = @import("std");
const zx = @import("zx");
const Function = @import("../../function.zig");
const Memo = @import("../../memo.zig");
const record = @import("../../memo/record.zig");
const publication = @import("../../memo/table/publication.zig");
const rows = @import("../../row_output.zig");
const entry = @import("generated_uniqueness_visit_adopt_plan");
const Input = std.meta.Child(entry.Input);
pub const Adopted = struct { record: Memo.Planned, row: ?u32 };

pub fn adopt(owner: std.mem.Allocator, plan: *const Function.Plan, memo: ?*Memo) std.mem.Allocator.Error!Adopted {
    var stored: record.Frame(.planned, rows.Target(Input, "memo")) = undefined;
    var host: publication.StoreHost(entry) = .{};

    if (memo) |cache| stored.open(cache);

    host.init(if (memo != null) stored.table.initial_used else 0, 0, false);

    const Source = rows.Target(Input, "source");

    const source = zx.columns.storage.view(Source, .{
        .flags = plan.flags,
        .renewals = &plan.renewals,
        .transfers = plan.transfers,
        .slot_first = plan.slot_first,
    });

    const input: Input = .{ .source = &source, .memo = if (memo != null) &stored.target else null };

    const retained = entry.executeIn(owner, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("plan adoption failed: {s}", .{@errorName(err)}),
    };

    const value = Memo.Planned.fromPlan(Function.Plan.fromColumns(retained.plan));

    if (memo != null) {
        stored.value = value;

        try stored.table.finish(host.state.*);
    }

    return .{
        .record = value,
        .row = if (retained.row) |row| @intCast(row) else null,
    };
}

pub fn run(owner: std.mem.Allocator, plan: *const Function.Plan, memo: ?*Memo) std.mem.Allocator.Error!Memo.Planned {
    return (try adopt(owner, plan, memo)).record;
}
