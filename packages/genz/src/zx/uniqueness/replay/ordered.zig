const std = @import("std");
const zx = @import("zx");
const views = @import("ordered/columns.zig");
const storage = zx.columns.storage;
const Memo = @import("../memo.zig");

pub fn agree(comptime kind: Memo.Kind, allocator: std.mem.Allocator, left: Memo.Result(kind), right: Memo.Result(kind)) std.mem.Allocator.Error!bool {
    if (kind == .planned) return comparePlan(allocator, &left, &right);

    const comparison = switch (kind) {
        .settled => @import("generated_uniqueness_replay_settled"),
        .demanded => @import("generated_uniqueness_replay_demanded"),
        .planned => unreachable,
    };

    const Input = std.meta.Child(comparison.Input);
    const View = std.meta.Child(@FieldType(Input, "left"));
    const Row = Memo.Result(kind);
    const old_rows: []const Row = @as(*const [1]Row, @ptrCast(&left));
    const new_rows: []const Row = @as(*const [1]Row, @ptrCast(&right));

    if (kind == .settled) {
        const before = views.Settled.init(&.{}, old_rows);
        const after = views.Settled.init(&.{}, new_rows);

        return evaluate(comparison, allocator, &.{ .left = &before.view(View), .right = &after.view(View), .previous = 0, .current = 0 });
    }

    const before = views.Demanded.init(&.{}, old_rows);
    const after = views.Demanded.init(&.{}, new_rows);
    var previous: views.Demanded.Binding(View) = undefined;
    var current: views.Demanded.Binding(View) = undefined;

    return evaluate(comparison, allocator, &.{ .left = &previous.init(&before), .right = &current.init(&after), .previous = 0, .current = 0 });
}

fn comparePlan(allocator: std.mem.Allocator, left: *const Memo.Planned, right: *const Memo.Planned) std.mem.Allocator.Error!bool {
    const comparison = @import("generated_uniqueness_replay_planned");
    const Parameter = @typeInfo(@TypeOf(comparison.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const Field = @FieldType(Input, "left");
    const referenced = @typeInfo(Field) == .pointer;
    const Record = if (referenced) std.meta.Child(Field) else Field;
    const left_view = plannedView(Record, left);
    const right_view = plannedView(Record, right);

    const input: Input = .{
        .left = if (referenced) &left_view else left_view,
        .right = if (referenced) &right_view else right_view,
    };

    return comparison.executeValue(allocator, if (indirect) &input else input) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("ordered replay comparison failed: {s}", .{@errorName(err)}),
    };
}

fn evaluate(comptime comparison: type, allocator: std.mem.Allocator, input: comparison.Input) std.mem.Allocator.Error!bool {
    return zx.columns.invoke(comparison.executeValue, allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("ordered replay comparison failed: {s}", .{@errorName(err)}),
    };
}

fn plannedView(comptime Target: type, plan: *const Memo.Planned) Target {
    return storage.view(Target, .{
        .flags = plan.flags,
        .renewals = &plan.renewals,
        .transfers = plan.transfers,
        .slot_first = plan.slot_first,
    });
}
