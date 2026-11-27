const std = @import("std");
const updates = @import("../../function/updates.zig");
const zx = @import("zx");
const Bodies = @import("../bodies.zig");
const Function = @import("../../function.zig");
const Growth = @import("../../growth.zig");
const Memo = @import("../../memo.zig");
const Slots = @import("../../slots.zig");
const Summaries = @import("../../summaries.zig");
const compute = @import("compute.zig");
const rows = @import("../../row_output.zig");
const record = @import("../../memo/record.zig");
const publication = @import("../../memo/table/publication.zig");
const adopt_plan = @import("adopt_plan.zig");
const generated = @import("generated_uniqueness_function_visit");
const body_view = @import("generated_uniqueness_body_view");
const Input = std.meta.Child(generated.Input);
const Body = std.meta.Child(body_view.Input);
const Error = std.mem.Allocator.Error;

const Frame = struct {
    body: Bodies.View,
    unit: *Bodies.Unit,
    growth: *Growth.Rows,
    slots: Slots,
    summaries: *Summaries,
    scratch: std.mem.Allocator,
    lasting: std.mem.Allocator,
    owner: std.mem.Allocator,
    restored_growth: bool = false,
    memo: ?*Memo = null,
};

pub fn run(comptime kind: Memo.Kind, comptime deferred: bool, in: compute.Input) Error!compute.Output(kind, deferred) {
    const unit = &in.bodies.units[in.body];

    return visit(kind, deferred, false, .{
        .body = Bodies.View.at(in.bodies.program, in.body),
        .unit = unit,
        .growth = in.growth orelse &unit.growth,
        .slots = in.slots,
        .summaries = in.summaries,
        .scratch = in.scratch,
        .lasting = in.lasting,
        .owner = in.owner,
        .restored_growth = in.restored_growth,
        .memo = in.memo,
    });
}

pub fn entry(owner: std.mem.Allocator, scratch: std.mem.Allocator, body: Bodies.View, unit: *Bodies.Unit, slots: Slots, summaries: *Summaries) Error!Function.Plan {
    const result = try visit(.planned, false, true, .{
        .body = body,
        .unit = unit,
        .growth = &unit.growth,
        .slots = slots,
        .summaries = summaries,
        .scratch = scratch,
        .lasting = scratch,
        .owner = owner,
    });

    return result.record.plan();
}

fn visit(comptime kind: Memo.Kind, comptime deferred: bool, comptime independent: bool, frame: Frame) Error!compute.Output(kind, deferred) {
    const facts = try frame.unit.facts(frame.lasting, frame.scratch, frame.body, frame.slots, frame.summaries);
    const metadata = frame.summaries;
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), frame.slots.types);
    const growth = frame.growth;
    var normalized: GrowthView = undefined;
    var renewed: GrowthView = undefined;

    normalized.init(growth.normalized);
    renewed.init(growth.renewed);

    const index = if (frame.body.function) |function| @as(?u32, @intCast(function)) else null;

    const body: Body = .{
        .facts = zx.columns.pointer(@FieldType(Body, "facts"), facts),
        .expressions = zx.columns.pointer(@FieldType(Body, "expressions"), frame.body.expressions),
        .layout = &.{ .offsets = frame.slots.offsets, .members = @ptrCast(frame.slots.members), .unwrapped = @ptrCast(frame.slots.unwrapped) },
        .counts = frame.slots.counts,
        .symbols = frame.body.symbols.count(),
        .index = index,
        .input = @ptrCast(&metadata.input),
        .output = @ptrCast(&metadata.output),
        .held = metadata.held,
        .written = metadata.written,
        .record = deferred,
        .normalized = &normalized.rows,
        .renewed = &renewed.rows,
    };

    const view = body_view.executeIn(frame.scratch, &body) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("ownership body view failed: {s}", .{@errorName(err)}),
    };

    var stored: record.Frame(kind, rows.Target(Input, "memo")) = undefined;
    var host: publication.StoreHost(generated) = .{};
    const inline_memo = kind != .planned and frame.memo != null;

    if (inline_memo) stored.open(frame.memo.?);

    host.init(if (inline_memo) stored.table.initial_used else 0, 0, false);

    const input: Input = .{
        .view = zx.columns.pointer(@FieldType(Input, "view"), view),
        .facts = zx.columns.pointer(@FieldType(Input, "facts"), facts),
        .index = index,
        .types = &types,
        .deferred = deferred,
        .independent = independent,
        .memo = if (inline_memo) &stored.target else null,
        .settlement = if (kind == .settled) &.{
            .input = @ptrCast(&metadata.input),
        } else null,
        .demand = if (kind == .demanded) &.{
            .exchange = &.{
                .return_allocations = metadata.return_allocations,
                .inputs = @ptrCast(&metadata.inputs),
                .outputs = @ptrCast(&metadata.outputs),
                .deferred = deferred,
            },
            .restored_growth = frame.restored_growth,
        } else null,
    };

    const value = generated.executeIn(frame.scratch, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("ownership visit failed: {s}", .{@errorName(err)}),
    };

    if (kind == .planned) {
        const plan = Function.Plan.fromColumns(value.plan.?);
        const adopted = try adopt_plan.adopt(frame.owner, &plan, frame.memo);

        return .{
            .record = adopted.record,
            .changed = if (deferred) {} else &.{},
            .reads = if (!deferred) {} else &.{},
            .row = adopted.row,
        };
    }

    const retained_reads = if (deferred) try rows.reads(frame.owner, value.reads) else {};

    errdefer if (deferred) frame.owner.free(retained_reads);

    var next_growth: ?Growth.Rows = null;

    const published: Memo.Result(kind) = switch (kind) {
        .settled => try rows.settlement(frame.owner, value),
        .demanded => demand: {
            const marks = try rows.marks(frame.owner, value.marks);

            errdefer frame.owner.free(marks);

            const updated = if (value.growth) |snapshot| try rows.growth(frame.owner, snapshot) else growth.*;

            next_growth = updated;

            break :demand .{
                .marks = marks,
                .normalized = updated.normalized,
                .renewed = updated.renewed,
                .grew = value.grew,
            };
        },
        .planned => unreachable,
    };

    if (inline_memo) {
        stored.value = published;

        try stored.table.finish(host.state.*);
    }

    if (next_growth) |updated| growth.* = updated;

    if (!deferred) {
        switch (kind) {
            .settled => updates.commit(metadata.input, &.{}, value.updates),
            .demanded => updates.commit(metadata.inputs, metadata.outputs, value.updates),
            .planned => unreachable,
        }
    }

    return .{
        .record = published,
        .changed = if (deferred) {} else value.changed,
        .reads = retained_reads,
        .row = if (value.row) |row| @intCast(row) else null,
    };
}

const GrowthView = struct {
    const Rows = std.meta.Child(@FieldType(Body, "normalized"));
    const Stored = std.meta.Child(@typeInfo(@FieldType(Rows, "stored")).optional.child);

    columns: Growth.Columns,
    stored: Stored,
    rows: Rows,
    fn init(self: *GrowthView, entries: anytype) void {
        self.rows = .{ .count = entries.len, .stored = null, .items = &.{} };

        if (entries.len == 0) return;

        self.columns = .borrow(entries);

        self.stored = .{
            .keys = @ptrCast(&self.columns.keys),
            .wants = @ptrCast(&self.columns.wants),
            .bytes = std.mem.sliceAsBytes(entries),
            .wide = self.columns.wide,
        };

        self.rows.stored = &self.stored;
    }
};
