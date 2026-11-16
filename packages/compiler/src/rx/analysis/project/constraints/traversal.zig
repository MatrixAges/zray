const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const condition = @import("../../condition.zig");
const Graph = @import("../../inference/types.zig");
const Scope = @import("../../inference/scope.zig");
const Flow = @import("../flow.zig");
const traversal = @import("../flow/traversal.zig");
const Cursor = traversal.Cursor;
const Region = traversal.Region;
const inline_frames = 4;

const Task = struct {
    item: u32,
    bindings: usize,
    output: Graph.Id,
    returned: bool,
};

const Selection = struct {
    cases: []Flow.Case,
    subject: Graph.Id,
    parsed: frontend.ExpressionInput.Result,
    labels: condition.Cases,
};

const Payload = union(Region) {
    Root: void,
    Task: Task,
    ParallelTask: Task,
    Parallel: Scope.Storage,
    Selection: Selection,
    Case: struct { bindings: usize, facts: usize },
};

const Frame = struct {
    cursor: Cursor,
    payload: Payload,
    fn release(self: *Frame, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .Selection => |*selection| {
                selection.labels.deinit();
                selection.parsed.deinit();
            },
            .Parallel => |*outputs| outputs.deinit(allocator),
            else => {},
        }
    }
};

pub fn run(walker: anytype, body: Flow.Unit) zx.Error!void {
    const plan = &walker.module.plan;
    const expression = walker.expression;
    var buffer: [@sizeOf(Frame) * inline_frames]u8 align(@alignOf(Frame)) = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, expression.scope);
    const allocator = scratch.allocator();
    var stack: std.ArrayList(Frame) = .empty;
    var root: Frame = .{ .cursor = Cursor.body(body), .payload = .Root };

    defer {
        while (stack.pop()) |frame| {
            var closing = frame;

            closing.release(expression.scope);
        }

        stack.deinit(allocator);
    }

    while (true) {
        const frame = if (stack.items.len == 0) &root else &stack.items[stack.items.len - 1];
        const region = std.meta.activeTag(frame.payload);
        const first = frame.cursor.first;
        const event = frame.cursor.advance(region, plan);

        switch (event.action) {
            .Done => return,
            .Calls => {
                const outputs = if (region == .Parallel) &frame.payload.Parallel else &expression.bindings;

                for (event.items) |item| try walker.call(item, outputs);
            },
            .Return => try walker.inferReturn(plan.results[event.items[0]]),
            .OpenTask, .OpenParallelTask => {
                const item = event.items[0];
                const task = &plan.tasks[item];
                const saved: Task = .{ .item = item, .bindings = expression.bindings.len, .output = walker.output, .returned = walker.returned };
                const parallel = event.action == .OpenParallelTask;
                const child = try stack.addOne(allocator);

                child.* = .{
                    .cursor = Cursor.body(task.body),
                    .payload = if (parallel) .{ .ParallelTask = saved } else .{ .Task = saved },
                };

                if (parallel) try walker.enterParallelTask(task);
            },
            .OpenParallel => {
                const child = try stack.addOne(allocator);
                child.* = .{ .cursor = Cursor.body(plan.groups[event.items[0]]), .payload = .{ .Parallel = .empty } };
            },
            .OpenSelection => {
                const selection = &plan.selections[event.items[0]];
                const owner = walker.module.source.path;
                var parsed = try @import("../../attribute.zig").parseBorrowed(expression.scope, selection.subject.*, owner);

                errdefer parsed.deinit();

                const subject = try walker.inferParsed(&parsed, selection.subject.*, null);
                const child = try stack.addOne(allocator);

                child.* = .{ .cursor = Cursor.cases(selection.cases.len), .payload = .{ .Selection = .{
                    .cases = selection.cases,
                    .subject = subject,
                    .parsed = parsed,
                    .labels = .{ .allocator = expression.scope, .owner = owner },
                } } };
            },
            .OpenCase => {
                const selection = &frame.payload.Selection;
                const bindings = expression.bindings.len;
                const facts = try walker.enterCase(&selection.parsed, selection.subject, &selection.labels, selection.cases, first);
                const unit = selection.cases[first].body;
                const child = try stack.addOne(allocator);
                child.* = .{ .cursor = Cursor.body(unit), .payload = .{ .Case = .{ .bindings = bindings, .facts = facts } } };
            },
            .CloseTask, .CloseParallelTask => {
                const parallel = event.action == .CloseParallelTask;
                const saved = if (parallel) frame.payload.ParallelTask else frame.payload.Task;
                const outputs = if (parallel) &stack.items[stack.items.len - 2].payload.Parallel else &expression.bindings;

                try walker.finishTask(&plan.tasks[saved.item], parallel, saved.bindings, saved.output, saved.returned, outputs);

                _ = stack.pop();
            },
            .CloseParallel => {
                try Scope.publishParallel(expression.graph, &expression.bindings, expression.scope, frame.payload.Parallel.slice());

                frame.release(expression.scope);

                _ = stack.pop();
            },
            .CloseSelection => {
                frame.release(expression.scope);

                _ = stack.pop();
            },
            .CloseCase => {
                expression.nonnull.shrinkRetainingCapacity(frame.payload.Case.facts);
                expression.bindings.shrinkRetainingCapacity(frame.payload.Case.bindings);

                _ = stack.pop();
            },
        }
    }
}
