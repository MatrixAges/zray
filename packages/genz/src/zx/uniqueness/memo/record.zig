const std = @import("std");
const zx = @import("zx");
const Memo = @import("../memo.zig");
const rows = @import("../row_output.zig");
const publication = @import("table/publication.zig");

pub fn Frame(comptime kind: Memo.Kind, comptime Target: type) type {
    const Value = Memo.Result(kind);
    const Writer = rows.Target(Target, "writer");
    const Store = rows.Target(Writer, "table");
    const Settlement = rows.Target(Target, "settlement");
    const Demand = rows.Target(Target, "demand");
    const Plan = rows.Target(Target, "plan");

    const Shape = switch (kind) {
        .settled => struct { passed: @FieldType(Settlement, "passed"), levels: @FieldType(Settlement, "levels") },
        .demanded => struct {
            mark_column: @FieldType(Demand, "mark_column"),
            normalized: @FieldType(Demand, "normalized"),
            renewed: @FieldType(Demand, "renewed"),
            grew: @FieldType(Demand, "grew"),
        },
        .planned => Plan,
    };

    const fields = switch (kind) {
        .settled => .{ .passed = &.{"passed"}, .levels = &.{"output"} },
        .demanded => .{ .mark_column = &.{"marks"}, .normalized = &.{"normalized"}, .renewed = &.{"renewed"}, .grew = &.{"grew"} },
        .planned => .{
            .flags = &.{"flags"},
            .keys = &.{ "renewals", "keys" },
            .paths = &.{ "renewals", "paths" },
            .transfers = &.{"transfers"},
            .slot_first = &.{"slot_first"},
        },
    };

    const Phase = switch (kind) {
        .settled => Settlement,
        .demanded => Demand,
        .planned => void,
    };

    return struct {
        const Self = @This();

        table: publication.Write(@FieldType(Memo, @tagName(kind))),
        value: Value,
        output: zx.memory.RowOutput(Value, Shape, fields),
        store: Store,
        writer: Writer,
        phase: Phase,
        target: Target,
        pub fn open(self: *Self, memo: *Memo, payload: anytype) void {
            self.table.open(&@field(memo, @tagName(kind)), memo.arena.child_allocator, &memo.changed);

            self.value = switch (kind) {
                .settled => .{ .passed = &.{}, .output = &.{} },
                .demanded => .{ .marks = &.{}, .normalized = &.{}, .renewed = &.{}, .grew = false },
                .planned => .{ .flags = &.{}, .renewals = .{} },
            };

            self.output.init();
            self.output.bind(@as(*[1]Value, @ptrCast(&self.value)));

            self.store = self.table.view(Store, &memo.key);

            self.writer = .{
                .table = &self.store,
                .value = std.mem.asBytes(&self.value),
            };

            self.phase = switch (kind) {
                .settled => .{
                    .contributions = @ptrCast(payload.passed),
                    .passed = self.output.view.passed,
                    .levels = self.output.view.levels,
                },
                .demanded => .{
                    .marks = @ptrCast(payload.marks),
                    .mark_column = self.output.view.mark_column,
                    .normalized = self.output.view.normalized,
                    .renewed = self.output.view.renewed,
                    .source_normalized = std.mem.asBytes(&payload.growth.normalized),
                    .source_renewed = std.mem.asBytes(&payload.growth.renewed),
                    .grew = self.output.view.grew,
                },
                .planned => {},
            };

            self.target = .{
                .writer = &self.writer,
                .settlement = if (kind == .settled) &self.phase else null,
                .demand = if (kind == .demanded) &self.phase else null,
                .plan = if (kind == .planned) &self.output.view else null,
            };
        }
    };
}
