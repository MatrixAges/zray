const std = @import("std");
const zx = @import("zx");
const Context = @import("../../program/host.zig").Context;
const Memo = @import("../../memo.zig");
const Trace = @import("../../trace.zig");
const Cursor = @import("../shortcut.zig");
const Replacements = @import("replacements.zig");
const Growth = @import("../../growth.zig");
const scanning = @import("generated_uniqueness_shortcut_scan");
const Input = std.meta.Child(scanning.Input);
const Tables = std.meta.Child(@FieldType(Input, "tables"));
const Settlement = std.meta.Child(@FieldType(Tables, "settled"));
const Demand = std.meta.Child(@FieldType(Tables, "demanded"));
const DemandBinding = Views.Demanded.Binding(std.meta.Child(@FieldType(Demand, "trace")));
const Index = std.meta.Child(@FieldType(Settlement, "index"));
const Probe = std.meta.Child(@FieldType(Index, "table"));
const Views = @import("../ordered/columns.zig");
const Error = std.mem.Allocator.Error;
pub const Prepared = struct { cursor: Cursor, growth: Growth.Rows };

pub fn advance(ctx: *Context, trace: *const Trace, scratch: std.mem.Allocator, staged: std.mem.Allocator, replacements: *Replacements, cursor: Cursor, recovered: ?u32) Error!Prepared {
    var settled: BoundIndex = undefined;
    var demanded: BoundIndex = undefined;
    var planned: BoundIndex = undefined;

    settled.init(&ctx.memo.settled, trace.settled.entries);
    demanded.init(&ctx.memo.demanded, trace.demanded.entries);
    planned.init(&ctx.memo.planned, trace.planned.entries);

    const previous_settled = Views.Settled.init(&.{"value"}, trace.settled.entries);
    const current_settled = Views.Settled.init(&.{}, ctx.memo.settled.values.items);
    const previous_demanded = Views.Demanded.init(&.{"value"}, trace.demanded.entries);
    const current_demanded = Views.Demanded.init(&.{}, ctx.memo.demanded.values.items);
    var previous_binding: DemandBinding = undefined;
    var current_binding: DemandBinding = undefined;
    const digests = zx.memory.borrowNestedColumn(Memo.Digest, &.{}, ctx.bodies.identities);
    const demands = ctx.summaries.storage.?.demands;

    const input: Input = .{
        .replay = &.{
            .active = ctx.calls.active,
            .settled = trace.settled.starts,
            .demanded = trace.demanded.starts,
            .planned = trace.planned.starts,
            .changed = ctx.replay.changed,
            .agreed = cursor.phase == .start,
            .demand_count = demands.len,
            .cursor = &.{ .body = cursor.body, .visit = cursor.visit, .phase = @fromBackingInt(@intCast(@backingInt(cursor.phase))) },
        },
        .tables = &.{
            .settled = &.{
                .index = &settled.view(),
                .trace = &previous_settled.view(std.meta.Child(@FieldType(Settlement, "trace"))),
                .memo = &current_settled.view(std.meta.Child(@FieldType(Settlement, "memo"))),
            },
            .demanded = &.{
                .index = &demanded.view(),
                .trace = &previous_binding.init(&previous_demanded),
                .memo = &current_binding.init(&current_demanded),
            },
            .planned = &planned.view(),
            .identities = @ptrCast(&digests),
            .digest_width = @sizeOf(Memo.Digest),
        },
        .recovery = &.{
            .callees = ctx.bodies.callees,
            .summaries = &.{
                .input = @ptrCast(&ctx.summaries.input),
                .output = @ptrCast(&ctx.summaries.output),
                .inputs = @ptrCast(&ctx.summaries.inputs),
                .outputs = @ptrCast(&ctx.summaries.outputs),
            },
        },
        .recovered = recovered,
    };

    const result = zx.columns.invoke(scanning.executeValue, scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("ownership replay scan failed: {s}", .{@errorName(err)}),
    };

    try replacements.items.ensureUnusedCapacity(staged, result.replacements.len);

    for (result.replacements) |replacement| {
        replacements.items.appendAssumeCapacity(.{
            .visit = replacement.visit,
            .value = ctx.memo.planned.values.items[replacement.row],
        });
    }

    if (result.cleared) |cleared| @memcpy(demands, cleared);
    if (result.digest) |digest| @memcpy(&ctx.memo.key, digest);

    for (result.hits) |hit| switch (hit.phase) {
        .Settled => ctx.memo.settled.values.items[hit.row].used = true,
        .Demanded => ctx.memo.demanded.values.items[hit.row].used = true,
        .Planned => ctx.memo.planned.values.items[hit.row].used = true,
        else => unreachable,
    };

    const growth = if (result.restored) |restored| try installGrowth(scratch, restored) else Growth.Rows{};

    return .{
        .cursor = .{
            .body = @intCast(result.cursor.body),
            .visit = @intCast(result.cursor.visit),
            .phase = @fromBackingInt(@intCast(@backingInt(result.cursor.phase))),
        },
        .growth = growth,
    };
}

fn installGrowth(allocator: std.mem.Allocator, restored: anytype) Error!Growth.Rows {
    const Level = @import("../../level.zig").Level;
    const normalized = try allocator.alloc(Growth.Normalized, restored.normalized.len);
    const renewed = try allocator.alloc(Growth.Renewed, restored.renewed.len);

    for (normalized, restored.normalized) |*row, value| {
        row.* = .{ .id = @fromBackingInt(value.id), .want = @bitCast(@as(u3, @intCast(value.want))) };
    }

    for (renewed, restored.renewed) |*row, value| {
        row.* = .{ .key = value.key, .want = @as(Level, @bitCast(@as(u3, @intCast(value.want)))) };
    }

    return .{ .normalized = normalized, .renewed = renewed };
}

const BoundIndex = struct {
    states: zx.memory.ListColumn,
    probe: Probe,
    fn init(self: *@This(), table: anytype, entries: anytype) void {
        self.states = zx.memory.borrowSliceColumn(&.{"state"}, entries);
        self.probe = table.probe(Probe);
    }

    fn view(self: *const @This()) Index {
        return .{ .table = &self.probe, .states = @ptrCast(&self.states) };
    }
};
