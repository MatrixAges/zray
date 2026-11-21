const std = @import("std");
const zx = @import("zx");
const Function = @import("../../function.zig");
const Memo = @import("../../memo.zig");
const record = @import("../../memo/record.zig");
const rows = @import("../../row_output.zig");
const entry = @import("generated_uniqueness_visit_adopt_plan");
const Input = std.meta.Child(entry.Input);

pub fn run(owner: std.mem.Allocator, plan: *const Function.Plan, memo: ?*Memo) std.mem.Allocator.Error!Memo.Planned {
    var scope = zx.memory.ArenaScope{ .active = owner };
    var stored: record.Frame(.planned, rows.Target(Input, "memo")) = undefined;

    if (memo) |cache| stored.open(cache, &scope, &owner, {});

    defer if (memo != null) stored.table.finish();

    const Source = rows.Target(Input, "source");

    const source = zx.columns.storage.view(Source, .{
        .flags = plan.flags,
        .renewals = &plan.renewals,
        .transfers = plan.transfers,
        .slot_first = plan.slot_first,
    });

    const input: Input = .{ .source = &source, .memo = if (memo != null) &stored.target else null };

    const retained = zx.columns.invoke(entry.executeValue, scope.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("plan adoption failed: {s}", .{@errorName(err)}),
    };

    return if (memo != null) stored.value else Memo.Planned.fromPlan(Function.Plan.fromColumns(retained));
}
