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

const Walker = @import("../constraints.zig").Walker;

pub const Host = struct {
    walker: *Walker,
    root: Frame,
    stack: std.ArrayList(Frame) = .empty,
    memory: std.mem.Allocator,
    pub fn frame(self: *Host) *Frame {
        if (self.stack.items.len == 0) return &self.root;

        return &self.stack.items[self.stack.items.len - 1];
    }
    pub fn pop(self: *Host) void {
        const last = self.stack.items.len - 1;

        self.stack.items[last].release(self.walker.expression.scope);

        self.stack.items.len = last;
    }

    pub fn calls(self: *Host, current: *Frame, _: usize, items: []const u32) zx.Error!void {
        const outputs = self.callOutputs(current);

        for (items) |item| try self.walker.call(item, outputs);
    }

    pub fn callOutputs(self: *Host, current: *Frame) *Scope.Storage {
        return if (current.payload == .Parallel) &current.payload.Parallel else &self.walker.expression.bindings;
    }
    pub fn result(self: *Host, _: *Frame, _: usize, item: u32) zx.Error!void {
        const walker = self.walker;
        const plan = &walker.module.plan;

        try walker.inferReturn(plan.results[item]);

        walker.returned = true;
    }

    pub fn task(self: *Host, _: *Frame, _: usize, item: u32, parallel_task: bool) zx.Error!void {
        const walker = self.walker;
        const plan = &walker.module.plan;
        const target = &plan.tasks[item];
        const saved: Task = .{ .item = item, .bindings = walker.expression.bindings.len, .output = walker.output, .returned = walker.returned };
        const child = try self.stack.addOne(self.memory);

        child.* = .{
            .cursor = Cursor.body(target.body),
            .payload = if (parallel_task) .{ .ParallelTask = saved } else .{ .Task = saved },
        };

        if (parallel_task) try walker.enterParallelTask(target);
    }
    pub fn parallel(self: *Host, _: *Frame, _: usize, item: u32) zx.Error!void {
        const plan = &self.walker.module.plan;
        const child = try self.stack.addOne(self.memory);
        child.* = .{ .cursor = Cursor.body(plan.groups[item]), .payload = .{ .Parallel = .empty } };
    }
    pub fn selection(self: *Host, _: *Frame, _: usize, item: u32) zx.Error!void {
        const walker = self.walker;
        const plan = &walker.module.plan;
        const selected = &plan.selections[item];
        const owner = walker.module.source.path;
        const scope = walker.expression.scope;
        var parsed = try @import("../../attribute.zig").parseBorrowed(scope, selected.subject.*, owner);

        errdefer parsed.deinit();

        const subject = try walker.inferParsed(&parsed, selected.subject.*, null);
        const child = try self.stack.addOne(self.memory);

        child.* = .{ .cursor = Cursor.cases(selected.cases.len), .payload = .{ .Selection = .{
            .cases = selected.cases,
            .subject = subject,
            .parsed = parsed,
            .labels = .{ .allocator = scope, .owner = owner },
        } } };
    }
    pub fn openCase(self: *Host, current: *Frame, first: usize) zx.Error!void {
        const walker = self.walker;
        const bindings = walker.expression.bindings.len;
        const selected = &current.payload.Selection;

        if (selected.cases[first].label.kind == .Default) {
            selected.cases[first].truth = try selected.labels.remaining(selected.cases[first + 1 ..]);
        } else {
            const truth = try self.labelCase(current, first);

            selected.cases[first].truth = truth;

            selected.labels.observe(truth);
        }

        const facts = walker.expression.nonnull.items.len;

        try self.refineCase(current, first);
        try self.pushCase(current, first, bindings, facts);
    }
    pub fn labelCase(self: *Host, current: *Frame, first: usize) zx.Error!?bool {
        const selected = &current.payload.Selection;
        const case = &selected.cases[first];
        const attribute = case.label.attribute() orelse return null;
        var label = try selected.labels.label(attribute);

        defer label.deinit();

        _ = try self.walker.inferParsed(&label, attribute, selected.subject);

        return condition.boolean(&label);
    }
    pub fn refineCase(self: *Host, current: *Frame, first: usize) zx.Error!void {
        const selected = &current.payload.Selection;
        const expression = self.walker.expression;

        if (selected.cases[first].truth) |present| {
            try condition.assumeParsed(expression.graph.scratch, &selected.parsed, present, expression.conditionScope());
        }
    }
    pub fn pushCase(self: *Host, current: *Frame, first: usize, bindings: usize, facts: usize) zx.Error!void {
        const unit = current.payload.Selection.cases[first].body;
        const child = try self.stack.addOne(self.memory);

        child.* = .{ .cursor = Cursor.body(unit), .payload = .{ .Case = .{ .bindings = bindings, .facts = facts } } };
    }

    pub fn closeTask(self: *Host, parallel_task: bool) zx.Error!void {
        const walker = self.walker;
        const current = self.frame();
        const saved = if (parallel_task) current.payload.ParallelTask else current.payload.Task;
        const outputs = if (parallel_task) &self.stack.items[self.stack.items.len - 2].payload.Parallel else &walker.expression.bindings;

        try walker.finishTask(&walker.module.plan.tasks[saved.item], parallel_task, saved.bindings, saved.output, saved.returned, outputs);
    }
    pub fn closeParallel(self: *Host) zx.Error!void {
        const expression = self.walker.expression;

        try Scope.publishParallel(expression.graph, &expression.bindings, expression.scope, self.frame().payload.Parallel.slice());
    }

    pub fn closeSelection(_: *Host) zx.Error!void {}

    pub fn closeCase(self: *Host) zx.Error!void {
        const expression = self.walker.expression;
        const saved = self.frame().payload.Case;

        expression.nonnull.shrinkRetainingCapacity(saved.facts);
        expression.bindings.shrinkRetainingCapacity(saved.bindings);
    }
};

pub fn run(walker: *Walker, body: Flow.Unit) zx.Error!void {
    var buffer: [inline_frames]Frame = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&buffer), walker.expression.scope);

    var state: Host = .{
        .walker = walker,
        .root = .{ .cursor = Cursor.body(body), .payload = .Root },
        .memory = scratch.allocator(),
    };

    defer {
        while (state.stack.items.len != 0) state.pop();

        state.stack.deinit(state.memory);
    }

    try traversal.run(&state, &walker.module.plan);
}
