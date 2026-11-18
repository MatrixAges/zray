const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Statements = @import("../statements.zig");
const Flow = @import("../flow.zig");
const Writer = @import("../control/writer.zig");
const inlineValue = @import("../expression.zig").inlineValue;
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_statement_advance") else void;
const Input = if (generated) std.meta.Child(rule.Input) else @import("traversal/seed.zig").Input;
const Shape = if (generated) std.meta.Child(@FieldType(Input, "shape")) else void;
const Region = if (generated) @FieldType(Input, "region") else @import("traversal/seed.zig").Region;
const inline_depth = 4;

const Cursor = struct {
    position: usize,
    end: usize,
    pub fn range(first: u32, count: u32) Cursor {
        return .{ .position = first, .end = @as(usize, first) + count };
    }
};

const Frame = struct {
    cursor: Cursor,
    // An inline unit borrows its enclosing block's writer by index across stack growth.
    block: ?usize = null,
    step: usize = 0,
    scope: union(Region) {
        Root: void,
        Task: usize,
        Selection: ir.ExprId,
        Case: struct {
            unit: u32,
            target: u32,
            label: ?ir.ExprId,
            bindings: usize,
            writer: Writer.Cursor,
        },
    },
};

pub fn lower(self: *const Statements, allocator: std.mem.Allocator, root_writer: *Writer.Cursor) Statements.Error!void {
    const flow = self.flow;
    const steps = flow.steps.slice();
    const cases = flow.cases.slice();
    const units = flow.units.slice();
    const builder = self.builder;
    const owner = self.plan.root();

    const step_columns: if (generated) std.meta.Child(@FieldType(Shape, "steps")) else void = if (generated) .{
        .kinds = zx.columns.slice(@FieldType(std.meta.Child(@FieldType(Shape, "steps")), "kinds"), @as([]const Flow.Kind, steps.items(.kind))),
        .outputs = zx.columns.slice(@FieldType(std.meta.Child(@FieldType(Shape, "steps")), "outputs"), @as([]const Flow.Publish, steps.items(.output))),
        .firsts = steps.items(.first),
        .counts = steps.items(.count),
        .exhaustive = steps.items(.exhaustive),
    } else {};

    const unit_columns: if (generated) std.meta.Child(@FieldType(Shape, "units")) else void = if (generated) .{
        .firsts = units.items(.first),
        .counts = units.items(.count),
    } else {};

    const shape: Shape = if (generated) .{
        .steps = &step_columns,
        .units = &unit_columns,
        .cases = cases.items(.body),
    } else {};

    const unit = flow.units.get(owner);
    var root: Frame = .{ .cursor = .range(unit.first, unit.count), .scope = .Root };
    var buffer: [inline_depth]Frame = undefined;
    var storage = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&buffer), allocator);
    const temporary = storage.allocator();
    var stack: std.ArrayList(Frame) = .empty;

    defer {
        while (stack.pop()) |frame| switch (frame.scope) {
            .Case => |branch| builder.bindings.shrinkRetainingCapacity(branch.bindings),
            else => {},
        };

        stack.deinit(temporary);
    }

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (true) {
        const frame = if (stack.items.len == 0) &root else &stack.items[stack.items.len - 1];
        const region = std.meta.activeTag(frame.scope);
        const first = frame.cursor.position;
        const block = frame.block;
        const writer = if (block) |index| &stack.items[index].scope.Case.writer else root_writer;

        const input: Input = .{
            .shape = if (generated) &shape else {},
            .region = region,
            .position = first,
            .end = frame.cursor.end,
            .scope_step = frame.step,
            .case_first = writer.counts.cases,
            .borrow_root = self.retain_metadata,
        };

        const event = if (comptime generated) zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch return error.InvalidModule else @import("traversal/seed.zig").advance(flow, input);
        const position: usize = @intCast(event.position);

        frame.cursor.position = @intCast(event.next);

        if (first < position) {
            for (steps.items(.first)[first..position]) |call| try self.call(writer, &self.calls[call]);
        }

        switch (event.action) {
            .Done => return,
            .Parallel => try self.parallel(writer, self.calls[event.first.?..][0..event.count.?]),
            .Return, .ReturnBorrowed => {
                const program = steps.items(.value)[position].?;

                self.writer.result(writer, try inlineValue(builder, program.*, event.action == .ReturnBorrowed));
            },
            .OpenTask => try stack.append(temporary, .{
                .cursor = .range(event.first.?, event.count.?),
                .block = block,
                .step = position,
                .scope = .{ .Task = builder.bindings.items.len },
            }),
            .OpenSelection => {
                const subject = try inlineValue(builder, steps.items(.value)[position].?.*, false);

                try stack.append(temporary, .{
                    .cursor = .range(event.first.?, event.count.?),
                    .block = block,
                    .step = position,
                    .scope = .{ .Selection = subject },
                });
            },
            .OpenCase => {
                const label = if (cases.items(.value)[position]) |program| try inlineValue(builder, program.*, false) else null;
                const child = event.unit.?;

                try stack.append(temporary, .{
                    .cursor = .range(event.first.?, event.count.?),
                    .block = stack.items.len,
                    .scope = .{ .Case = .{
                        .unit = child,
                        .target = event.target.?,
                        .label = label,
                        .bindings = builder.bindings.items.len,
                        .writer = Writer.Cursor.init(self.plan.rows[child].first),
                    } },
                });
            },
            .CloseTask => try self.finishTask(.Task, writer, frame.step, frame.scope.Task),
            .EvaluateTask => try self.finishTask(.TaskWithEvaluation, writer, frame.step, frame.scope.Task),
            .BindTask => try self.finishTask(.TaskWithBinding, writer, frame.step, frame.scope.Task),
            .CloseSelection => {
                self.writer.selection(writer, frame.scope.Selection, event.count.?, event.exhaustive.?);
            },
            .CloseCase => {
                const branch = &frame.scope.Case;
                const row = self.plan.rows[branch.unit];

                try self.writer.finishCase(writer, row.tag, self.plan.end(branch.unit), branch.target, branch.label);

                builder.bindings.shrinkRetainingCapacity(branch.bindings);
            },
        }

        if (event.pop) _ = stack.pop();
    }
}
