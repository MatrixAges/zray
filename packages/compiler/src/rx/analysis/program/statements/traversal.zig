const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Statements = @import("../statements.zig");
const Flow = @import("../flow.zig");
const Writer = @import("../control/writer.zig");
const inlineValue = @import("../expression.zig").inlineValue;

const Scope = struct {
    bindings: usize = 0,
    value: ?ir.ExprId = null,
};

pub fn lower(self: *const Statements, allocator: std.mem.Allocator, root_writer: *Writer.Cursor) Statements.Error!void {
    if (comptime !@import("rx_options").generated_graph) return @import("traversal/seed.zig").lower(self, allocator, root_writer);

    const rule = @import("generated_rx_statement_schedule_body");
    const Input = std.meta.Child(rule.Input);
    const Shape = std.meta.Child(@FieldType(Input, "shape"));
    const Steps = std.meta.Child(@FieldType(Shape, "steps"));
    const flow = self.flow;
    const steps = flow.steps.slice();
    const cases = flow.cases.slice();
    const units = flow.units.slice();
    const layout = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(self.plan.rows));

    const input: Input = .{
        .shape = &.{
            .steps = &.{
                .kinds = zx.columns.slice(@FieldType(Steps, "kinds"), @as([]const Flow.Kind, steps.items(.kind))),
                .outputs = zx.columns.slice(@FieldType(Steps, "outputs"), @as([]const Flow.Publish, steps.items(.output))),
                .firsts = steps.items(.first),
                .counts = steps.items(.count),
                .exhaustive = steps.items(.exhaustive),
            },
            .units = &.{
                .firsts = units.items(.first),
                .counts = units.items(.count),
                .blocks = units.items(.block),
            },
            .cases = cases.items(.body),
        },
        .layout = layout,
        .borrow_root = self.retain_metadata,
    };

    const schedule = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const scopes = try allocator.alloc(Scope, @intCast(schedule.slots));
    const root = self.plan.root();
    const writers = try allocator.alloc(Writer.Cursor, self.plan.rows[root].tag);
    const builder = self.builder;
    const bindings = builder.bindings.items.len;

    errdefer builder.bindings.shrinkRetainingCapacity(bindings);

    for (schedule.events) |event| {
        const row = &self.plan.rows[event.block];
        const writer = if (event.block == root) root_writer else &writers[row.tag];

        switch (event.action) {
            .Calls => for (steps.items(.first)[event.first..][0..event.count]) |call| try self.call(writer, &self.calls[call]),
            .Parallel => try self.parallel(writer, self.calls[event.first..][0..event.count]),
            .Return, .ReturnBorrowed => {
                const value = try inlineValue(builder, steps.items(.value)[event.first].?.*, event.action == .ReturnBorrowed);

                self.writer.result(writer, value);
            },
            .OpenTask => scopes[event.slot] = .{ .bindings = builder.bindings.items.len },
            .OpenSelection => {
                const value = try inlineValue(builder, steps.items(.value)[event.first].?.*, false);

                scopes[event.slot] = .{ .value = value };
            },
            .OpenCase => {
                const label = if (cases.items(.value)[event.first]) |program| try inlineValue(builder, program.*, false) else null;

                scopes[event.slot] = .{ .bindings = builder.bindings.items.len, .value = label };
                writer.* = Writer.Cursor.init(row.first);
            },
            .CloseTask => try self.finishTask(.Task, writer, event.first, scopes[event.slot].bindings),
            .EvaluateTask => try self.finishTask(.TaskWithEvaluation, writer, event.first, scopes[event.slot].bindings),
            .BindTask => try self.finishTask(.TaskWithBinding, writer, event.first, scopes[event.slot].bindings),
            .CloseSelection => self.writer.selection(writer, scopes[event.slot].value.?, event.count, event.exhaustive),
            .CloseCase => {
                const scope = scopes[event.slot];
                const end = &self.plan.rows[event.count].first;

                try self.writer.finishCase(writer, row.tag, end, event.first, scope.value);

                builder.bindings.shrinkRetainingCapacity(scope.bindings);
            },
            .Done => unreachable,
        }
    }
}
