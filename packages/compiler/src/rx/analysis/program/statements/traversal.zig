const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Statements = @import("../statements.zig");
const Flow = @import("../flow.zig");
const Writer = @import("../control/writer.zig");
const inlineValue = @import("../expression.zig").inlineValue;
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_statement_traversal") else void;
const Input = if (generated) std.meta.Child(rule.Input) else void;
const Outcome = if (generated) @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload else void;
const Event = if (generated and @typeInfo(Outcome) == .pointer) std.meta.Child(Outcome) else Outcome;
const Region = if (generated) @FieldType(Input, "region") else enum { Root, Task, Selection, Case };

const Action = if (generated) @FieldType(Event, "action") else enum {
    Done,
    Call,
    Parallel,
    Return,
    OpenTask,
    OpenSelection,
    OpenCase,
    CloseTask,
    CloseSelection,
    CloseCase,
};

const inline_depth = 4;

const Cursor = struct {
    position: usize,
    end: usize,
    fn range(first: usize, count: usize) Cursor {
        return .{ .position = first, .end = first + count };
    }
    fn unit(flow: *const Flow, owner: u32) Cursor {
        const body = flow.units.get(owner);

        return range(body.first, body.count);
    }
    fn advance(self: *Cursor, region: Region, kinds: []const Flow.Kind) Action {
        if (comptime generated) {
            const input: Input = .{
                .region = region,
                .kinds = zx.columns.slice(@FieldType(Input, "kinds"), kinds),
                .position = self.position,
                .end = self.end,
            };

            var buffer: [@sizeOf(Event)]u8 align(@alignOf(Event)) = undefined;
            var scratch = std.heap.FixedBufferAllocator.init(&buffer);
            const event = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

            self.position = @intCast(event.next);

            return event.action;
        }

        if (self.position == self.end) return switch (region) {
            .Root => .Done,
            .Task => .CloseTask,
            .Selection => .CloseSelection,
            .Case => .CloseCase,
        };

        const position = self.position;

        self.position += 1;

        if (region == .Selection) return .OpenCase;

        return switch (kinds[position]) {
            .Call => .Call,
            .Parallel => .Parallel,
            .Return => .Return,
            .Task => .OpenTask,
            .Selection => .OpenSelection,
        };
    }
};

const Frame = struct {
    cursor: Cursor,
    /// Inline units borrow a cursor by stack index so growth cannot invalidate it.
    block: ?usize = null,
    scope: union(Region) {
        Root: void,
        Task: struct { step: usize, bindings: usize },
        Selection: struct { step: usize, subject: ir.ExprId, first: usize },
        Case: struct {
            unit: u32,
            target: usize,
            label: ?ir.ExprId,
            bindings: usize,
            writer: Writer.Cursor,
        },
    },
};

pub fn lower(self: *const Statements, allocator: std.mem.Allocator, owner: u32, root_writer: *Writer.Cursor) Statements.Error!void {
    const flow = self.flow;
    const steps = flow.steps.slice();
    const cases = flow.cases.slice();
    const builder = self.builder;
    const kinds = steps.items(.kind);
    var root: Frame = .{ .cursor = Cursor.unit(flow, owner), .scope = .Root };
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
        const position = frame.cursor.position;
        const block = frame.block;
        const writer = if (block) |index| &stack.items[index].scope.Case.writer else root_writer;

        switch (frame.cursor.advance(region, kinds)) {
            .Done => return,
            .Call => try self.call(writer, &self.calls[steps.items(.first)[position]]),
            .Parallel => {
                const first = steps.items(.first)[position];
                const count = steps.items(.count)[position];

                try self.parallel(writer, self.calls[first..][0..count]);
            },
            .Return => {
                const program = steps.items(.value)[position].?;
                const borrow = region == .Root and self.retain_metadata and owner == self.plan.root();

                self.writer.result(writer, try inlineValue(builder, program.*, borrow));
            },
            .OpenTask => {
                const child = try stack.addOne(temporary);

                child.* = .{
                    .cursor = Cursor.unit(flow, steps.items(.first)[position]),
                    .block = block,
                    .scope = .{ .Task = .{ .step = position, .bindings = builder.bindings.items.len } },
                };
            },
            .OpenSelection => {
                const subject = try inlineValue(builder, steps.items(.value)[position].?.*, false);
                const first = writer.counts.cases;
                const step_first = steps.items(.first)[position];
                const count = steps.items(.count)[position];
                const child = try stack.addOne(temporary);

                child.* = .{
                    .cursor = Cursor.range(step_first, count),
                    .block = block,
                    .scope = .{ .Selection = .{ .step = position, .subject = subject, .first = first } },
                };
            },
            .OpenCase => {
                const selection = frame.scope.Selection;
                const target = selection.first + position - steps.items(.first)[selection.step];
                const unit = cases.items(.body)[position];
                const label = try self.caseLabel(cases.items(.value)[position]);
                const index = stack.items.len;
                const child = try stack.addOne(temporary);

                child.* = .{
                    .cursor = Cursor.unit(flow, unit),
                    .block = index,
                    .scope = .{ .Case = .{
                        .unit = unit,
                        .target = target,
                        .label = label,
                        .bindings = builder.bindings.items.len,
                        .writer = Writer.Cursor.init(self.plan.rows[unit].first),
                    } },
                };
            },
            .CloseTask => {
                const task = frame.scope.Task;

                try self.finishTask(writer, steps.get(task.step), task.bindings);

                _ = stack.pop();
            },
            .CloseSelection => {
                const selection = frame.scope.Selection;

                self.writer.selection(writer, selection.subject, steps.items(.count)[selection.step], steps.items(.exhaustive)[selection.step]);

                _ = stack.pop();
            },
            .CloseCase => {
                const branch = &frame.scope.Case;
                const row = self.plan.rows[branch.unit];
                const body = try self.writer.finishBlock(writer, row.tag, self.plan.end(branch.unit));

                builder.bindings.shrinkRetainingCapacity(branch.bindings);
                self.writer.selectionCase(branch.target, branch.label, body);

                _ = stack.pop();
            },
        }
    }
}
