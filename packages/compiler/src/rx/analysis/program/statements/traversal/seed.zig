const std = @import("std");
const ir = @import("zx").ir;
const Flow = @import("../../flow.zig");
const Statements = @import("../../statements.zig");
const Writer = @import("../../control/writer.zig");
const inlineValue = @import("../../expression.zig").inlineValue;
pub const Region = enum { Root, Task, Selection, Case };

const Action = enum {
    Done,
    Parallel,
    Return,
    ReturnBorrowed,
    OpenTask,
    OpenSelection,
    OpenCase,
    CloseTask,
    EvaluateTask,
    BindTask,
    CloseSelection,
    CloseCase,
};

pub const Input = struct {
    region: Region,
    position: usize,
    end: usize,
    scope_step: usize,
    case_first: u32,
    borrow_root: bool,
};

const Event = struct {
    action: Action,
    next: usize,
    position: usize,
    pop: bool = false,
    first: ?u32 = null,
    count: ?u32 = null,
    unit: ?u32 = null,
    target: ?u32 = null,
    exhaustive: ?bool = null,
};

pub fn advance(flow: *const Flow, in: Input) Event {
    const steps = flow.steps.slice();
    const kinds = steps.items(.kind);
    var row = in.position;

    if (in.region != .Selection) {
        while (row < in.end and kinds[row] == .Call) row += 1;
    }

    if (row == in.end) return switch (in.region) {
        .Root => .{ .action = .Done, .next = row, .position = row },
        .Task => .{ .action = switch (steps.items(.output)[in.scope_step]) {
            .None => .CloseTask,
            .Evaluate => .EvaluateTask,
            .Constant => .BindTask,
        }, .next = row, .position = row, .pop = true },
        .Selection => .{ .action = .CloseSelection, .next = row, .position = row, .pop = true, .count = steps.items(.count)[in.scope_step], .exhaustive = steps.items(.exhaustive)[in.scope_step] },
        .Case => .{ .action = .CloseCase, .next = row, .position = row, .pop = true },
    };

    const next = row + 1;

    if (in.region == .Selection) {
        const child = flow.cases.items(.body)[row];
        const unit = flow.units.get(child);
        const offset: u32 = @intCast(row - steps.items(.first)[in.scope_step]);

        return .{ .action = .OpenCase, .next = next, .position = row, .first = unit.first, .count = unit.count, .unit = child, .target = in.case_first + offset };
    }

    return switch (kinds[row]) {
        .Call => unreachable,
        .Parallel => .{ .action = .Parallel, .next = next, .position = row, .first = steps.items(.first)[row], .count = steps.items(.count)[row] },
        .Return => .{ .action = if (in.region == .Root and in.borrow_root) .ReturnBorrowed else .Return, .next = next, .position = row },
        .Task => task: {
            const unit = flow.units.get(steps.items(.first)[row]);

            break :task .{ .action = .OpenTask, .next = next, .position = row, .first = unit.first, .count = unit.count };
        },
        .Selection => .{ .action = .OpenSelection, .next = next, .position = row, .first = steps.items(.first)[row], .count = steps.items(.count)[row] },
    };
}

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
    const builder = self.builder;
    const owner = self.plan.root();
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

    while (true) {
        const frame = if (stack.items.len == 0) &root else &stack.items[stack.items.len - 1];
        const region = std.meta.activeTag(frame.scope);
        const first = frame.cursor.position;
        const block = frame.block;
        const writer = if (block) |index| &stack.items[index].scope.Case.writer else root_writer;

        const input: Input = .{
            .region = region,
            .position = first,
            .end = frame.cursor.end,
            .scope_step = frame.step,
            .case_first = writer.counts.cases,
            .borrow_root = self.retain_metadata,
        };

        const event = advance(flow, input);
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
