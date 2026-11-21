const std = @import("std");
const zx = @import("zx");
const Context = @import("../../program/host.zig").Context;
const Memo = @import("../../memo.zig");
const Trace = @import("../../trace.zig");
const Cursor = @import("../shortcut.zig");
const Replacements = @import("replacements.zig");
const scanning = @import("generated_uniqueness_shortcut_scan");
const Input = std.meta.Child(scanning.Input);
const Tables = std.meta.Child(@FieldType(Input, "tables"));
const Settlement = std.meta.Child(@FieldType(Tables, "settled"));
const Demand = std.meta.Child(@FieldType(Tables, "demanded"));
const DemandBinding = Views.Demanded.Binding(std.meta.Child(@FieldType(Demand, "trace")));
const Index = std.meta.Child(@FieldType(Settlement, "index"));
const Probe = std.meta.Child(@FieldType(Index, "table"));
const Targets = std.meta.Child(@FieldType(Input, "replacements"));
const Views = @import("../ordered/columns.zig");
const Row = Cursor.Replacement;
const Error = std.mem.Allocator.Error;

pub fn advance(ctx: *Context, trace: *const Trace, scratch: *std.heap.ArenaAllocator, staged: std.mem.Allocator, replacements: *Replacements, cursor: Cursor, recovered: ?u32) Error!Cursor {
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
    const stored_plans = zx.memory.borrowNestedColumn(Memo.Planned, &.{}, ctx.memo.planned.values.items);
    const digests = zx.memory.borrowNestedColumn(Memo.Digest, &.{}, ctx.bodies.identities);
    const key: []u8 = &ctx.memo.key;
    const demands = &ctx.summaries.storage.?.demands;
    var scope = zx.memory.ArenaScope{ .active = staged };
    var output: zx.memory.RowOutput(Row, Columns, .{ .positions = &.{"visit"}, .values = &.{"value"} }) = undefined;

    output.init();
    output.bind(replacements.buffer.rows(Row));

    defer replacements.buffer.bytes = output.buffer.bytes;

    const input: Input = .{
        .replay = &.{
            .active = ctx.calls.active,
            .settled = trace.settled.starts,
            .demanded = trace.demanded.starts,
            .planned = trace.planned.starts,
            .changed = ctx.replay.changed,
            .agreed = cursor.phase == .start,
            .demands = &.{ .cells = @ptrCast(demands), .count = demands.len },
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
            .planned = &.{ .index = &planned.view(), .values = @ptrCast(&stored_plans), .width = @sizeOf(Memo.Planned) },
            .identities = @ptrCast(&digests),
            .digest = @ptrCast(&key),
            .digest_width = @sizeOf(Memo.Digest),
        },
        .replacements = &.{
            .rows = @ptrCast(&output.buffer),
            .positions = output.view.positions,
            .values = output.view.values,
            .width = @sizeOf(Row),
            .granule = @max(1, std.atomic.cache_line / @sizeOf(Row)),
        },
        .arenas = &.{ .scope = @ptrCast(&scope), .scratch = @ptrCast(scratch), .staged = @ptrCast(&staged) },
        .count = replacements.used,
        .recovered = recovered,
    };

    const result = zx.columns.invoke(scanning.executeValue, scope.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("ownership replay scan failed: {s}", .{@errorName(err)}),
    };

    replacements.used = @intCast(result.count);

    return .{
        .body = @intCast(result.cursor.body),
        .visit = @intCast(result.cursor.visit),
        .phase = @fromBackingInt(@intCast(@backingInt(result.cursor.phase))),
    };
}

const Columns = struct {
    positions: @FieldType(Targets, "positions"),
    values: @FieldType(Targets, "values"),
};

const BoundIndex = struct {
    used: zx.memory.WriteColumn,
    states: zx.memory.ListColumn,
    probe: Probe,
    fn init(self: *@This(), table: anytype, entries: anytype) void {
        self.used = table.useColumn();
        self.states = zx.memory.borrowSliceColumn(&.{"state"}, entries);
        self.probe = table.probe(Probe, &self.used);
    }

    fn view(self: *const @This()) Index {
        return .{ .table = &self.probe, .states = @ptrCast(&self.states) };
    }
};
