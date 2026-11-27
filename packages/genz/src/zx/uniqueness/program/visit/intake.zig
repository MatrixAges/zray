const std = @import("std");
const zx = @import("zx");
const Ahead = @import("../../ahead.zig");
const Function = @import("../../function.zig");
const Level = @import("../../level.zig").Level;
const Memo = @import("../../memo.zig");
const Trace = @import("../../trace.zig");
const Visit = @import("../../replay/root.zig").Visit;
const BodyRows = @import("../../memo/body_rows.zig");
const target = @import("../../row_output.zig").Target;
const Context = @import("../host.zig").Context;
const entry = @import("generated_uniqueness_visit_intake");
const Input = std.meta.Child(entry.Input);
const Probe = target(Input, "memo");
const Reads = std.meta.Child(@typeInfo(@FieldType(Input, "ahead_reads")).optional.child);
const Output = @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload;
pub const Origin = @FieldType(Output, "origin");

fn Decision(comptime kind: Memo.Kind) type {
    return struct { origin: Origin, cached: ?Memo.Result(kind), ahead: ?Ahead.Found(kind) };
}

pub fn run(comptime kind: Memo.Kind, comptime persistent: bool, ctx: *Context, scratch: *std.heap.ArenaAllocator, index: usize) std.mem.Allocator.Error!Decision(kind) {
    const ahead = &ctx.rounds.?.ahead;
    const memo = ctx.memo;
    const table = &@field(memo, @tagName(kind));
    const temporary = ctx.replay.allocator;
    const previous: ?*const Trace = if (persistent) ctx.replay.trace else null;
    const history: ?@FieldType(Trace, @tagName(kind)) = if (previous) |trace| @field(trace, @tagName(kind)) else null;
    const visit = if (history) |rows| ctx.replay.control.visit(Visit, kind, index, rows.starts, false) else undefined;
    const selection = if (history != null) visit.input(target(Input, "history")) else undefined;
    const Body = target(Probe, "rows");
    var views: BodyRows.Views(Body) = undefined;

    const probe: Probe = if (persistent) .{
        .rows = &ahead.memo_rows.view(Body, &views),
        .summaries = &BodyRows.summaries(target(Probe, "summaries"), ctx.summaries),
        .index = index,
        .kind = @fromBackingInt(@backingInt(kind)),
        .table = &table.probe(target(Probe, "table")),
    } else undefined;

    const worker = ahead.pool.count() != 0;
    const ahead_ready = if (worker) try @import("../../ahead/schedule.zig").take(ahead.states, ahead.dirty, index) else false;
    const slot = if (ahead_ready) ahead.resultSlot(kind, index) else null;
    var reads: ReadColumns = undefined;

    if (kind != .planned) _ = scratch.reset(.retain_capacity);

    const input: Input = .{
        .memo = if (persistent) &probe else null,
        .history = if (history != null) &selection else null,
        .ahead_ready = ahead_ready,
        .ahead_reads = if (ahead_ready and kind != .planned) &reads.bind(slot.?, ctx) else null,
    };

    const result = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("ownership visit intake failed: {s}", .{@errorName(err)}),
    };

    if (result.encoded) |encoded| try memo.encoding.capture(encoded);
    if (result.digest) |digest| @memcpy(&memo.key, digest);
    if (result.memo_row) |row| table.values.items[row].used = true;
    if (history != null) try visit.advance(temporary, result.next);
    if (kind == .planned and result.origin == .Analyze) _ = scratch.reset(.retain_capacity);
    if (!result.following) ctx.replay.trace = null;

    const cached = if (persistent) lookup: {
        if (result.trace_row) |row| {
            const recalled = history.?.entries[row];

            ctx.replay.recalled = recalled.state;

            break :lookup recalled.value;
        }

        break :lookup if (result.memo_row) |row| table.values.items[row] else null;
    } else null;

    return .{ .origin = result.origin, .cached = cached, .ahead = if (result.origin == .Ahead) slot.?.* else null };
}

const memory = zx.memory;
const table_info = @typeInfo(Function.Table).@"enum";
const Table = std.meta.Elem(@FieldType(Reads, "tables"));

const ReadColumns = struct {
    kinds: memory.ListColumn,
    functions: memory.ListColumn,
    slots: memory.ListColumn,
    values: memory.ListColumn,
    tables: [table_info.field_names.len]Table,
    fn bind(self: *@This(), slot: anytype, ctx: *const Context) Reads {
        const Row = std.meta.Child(@TypeOf(slot));
        const records: []const Row = @as(*const [1]Row, @ptrCast(slot));
        self.kinds = memory.borrowListPath(Function.Table, &.{"reads"}, &.{"table"}, records);
        self.functions = memory.borrowListPath(u32, &.{"reads"}, &.{"function"}, records);
        self.slots = memory.borrowListPath(u32, &.{"reads"}, &.{"slot"}, records);
        self.values = memory.borrowListPath(Level, &.{"reads"}, &.{"value"}, records);

        inline for (table_info.field_names, table_info.field_values) |name, value| {
            self.tables[value] = @ptrCast(&@field(ctx.summaries, name));
        }

        return .{
            .tables = &self.tables,
            .kinds = @ptrCast(&self.kinds),
            .functions = @ptrCast(&self.functions),
            .slots = @ptrCast(&self.slots),
            .values = @ptrCast(&self.values),
        };
    }
};
