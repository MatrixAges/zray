const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Compiler = @import("../flow_compile.zig");
const Flow = @import("../program/flow.zig");
const Prepared = @import("../project/flow.zig");
const condition = @import("../condition.zig");
const traversal = @import("../project/flow/traversal.zig");
const Cursor = traversal.Cursor;
const Region = traversal.Region;
const inline_frames = 4;

const Body = struct {
    first: u32,
    count: u32,
    fn reserve(compiler: *Compiler, unit: Prepared.Unit) Compiler.Error!Body {
        return .{ .first = try compiler.compiled.reserveSteps(compiler.binding_allocator, unit.count), .count = unit.count };
    }
    fn close(self: Body, compiler: *Compiler, block: bool) std.mem.Allocator.Error!u32 {
        return compiler.compiled.unit(compiler.binding_allocator, self.first, self.count, block);
    }
};

const Selection = struct {
    item: u32,
    parsed: frontend.ExpressionInput.Result,
    subject: *const zx.ir.Program,
};

const Payload = union(Region) {
    Root: void,
    Task: struct { item: u32, bindings: usize },
    ParallelTask: void,
    Parallel: frontend.expressions.BindingStorage,
    Selection: Selection,
    Case: struct { bindings: usize, facts: usize, label: ?*const zx.ir.Program },
};

const Frame = struct {
    cursor: Cursor,
    destination: u32 = 0,
    body: Body = undefined,
    payload: Payload,
    fn row(self: *const Frame, source: usize) u32 {
        const offset: u32 = @intCast(source - (self.cursor.end - self.body.count));

        return self.body.first + offset;
    }
    fn release(self: *Frame, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .Selection => |*selection| selection.parsed.deinit(),
            .Parallel => |*outputs| outputs.deinit(allocator),
            else => {},
        }
    }
};

pub const Host = struct {
    compiler: *Compiler,
    root: Frame,
    stack: std.ArrayList(Frame) = .empty,
    memory: std.mem.Allocator,
    pub fn frame(self: *Host) *Frame {
        if (self.stack.items.len == 0) return &self.root;

        return &self.stack.items[self.stack.items.len - 1];
    }
    pub fn pop(self: *Host) void {
        const last = self.stack.items.len - 1;

        self.stack.items[last].release(self.compiler.binding_allocator);

        self.stack.items.len = last;
    }

    pub fn calls(self: *Host, current: *Frame, first: usize, items: []const u32) Compiler.Error!void {
        const outputs = self.callOutputs(current);

        for (items, first..) |item, row| {
            const id = try self.compiler.call(item, outputs);

            if (current.payload == .Parallel) {
                try self.compiler.checkParallelCall(item, id);
            } else {
                self.compiler.compiled.steps.set(current.row(row), .{ .kind = .Call, .first = id });
            }
        }
    }

    pub fn callOutputs(self: *Host, current: *Frame) *frontend.expressions.BindingStorage {
        return if (current.payload == .Parallel) &current.payload.Parallel else &self.compiler.bindings;
    }

    pub fn result(self: *Host, current: *Frame, first: usize, item: u32) Compiler.Error!void {
        const value = try self.evaluateReturn(current, item);

        self.compiler.compiled.steps.set(current.row(first), .{ .kind = .Return, .value = value });
    }

    pub fn evaluateReturn(self: *Host, current: *Frame, item: u32) Compiler.Error!*const zx.ir.Program {
        const compiler = self.compiler;
        const publish = current.payload == .Root and compiler.retain_metadata;
        const value = try compiler.keep(try compiler.value(compiler.plan.results[item], compiler.output_type, publish));

        if (publish) compiler.root_return = value;

        return value;
    }
    pub fn task(self: *Host, current: *Frame, first: usize, item: u32, parallel_task: bool) Compiler.Error!void {
        const compiler = self.compiler;
        const plan = compiler.plan;

        if (parallel_task) {
            _ = try @import("../parallel_task.zig").compile(compiler, &plan.tasks[item], &current.payload.Parallel);

            return;
        }

        const unit = plan.tasks[item].body;
        const destination = current.row(first);
        const range = try Body.reserve(compiler, unit);
        const child = try self.stack.addOne(self.memory);

        child.* = .{ .cursor = Cursor.body(unit), .destination = destination, .body = range, .payload = .{
            .Task = .{ .item = item, .bindings = compiler.bindings.len },
        } };
    }

    pub fn parallel(self: *Host, current: *Frame, first: usize, item: u32) Compiler.Error!void {
        const compiler = self.compiler;
        const plan = compiler.plan;
        const branches = plan.groups[item];
        const destination = current.row(first);
        const first_call = try Flow.index(compiler.calls.items.len);
        const child = try self.stack.addOne(self.memory);

        child.* = .{
            .cursor = Cursor.body(branches),
            .destination = destination,
            .body = .{ .first = first_call, .count = branches.count },
            .payload = .{ .Parallel = .empty },
        };
    }

    pub fn selection(self: *Host, current: *Frame, first: usize, item: u32) Compiler.Error!void {
        const compiler = self.compiler;
        const plan = compiler.plan;
        const selected = &plan.selections[item];
        const destination = current.row(first);
        var parsed = try @import("../attribute.zig").parseBorrowed(compiler.scratch, selected.subject.*, compiler.owner);

        errdefer parsed.deinit();

        const subject = try compiler.keep(try compiler.valueParsed(&parsed, selected.subject.*, null, false));
        const count = try Flow.index(selected.cases.len);
        const cases = try compiler.compiled.reserveCases(compiler.binding_allocator, count);
        const child = try self.stack.addOne(self.memory);

        child.* = .{
            .cursor = Cursor.cases(count),
            .destination = destination,
            .body = .{ .first = cases, .count = count },
            .payload = .{ .Selection = .{ .item = item, .parsed = parsed, .subject = subject } },
        };
    }

    pub fn openCase(self: *Host, current: *Frame, first: usize) Compiler.Error!void {
        const bindings = self.compiler.bindings.len;
        const label = try self.labelCase(current, first);
        const facts = self.compiler.nonnull.items.len;

        try self.refineCase(current, first);
        try self.pushCase(current, first, bindings, facts, label);
    }
    pub fn labelCase(self: *Host, current: *Frame, row: usize) Compiler.Error!?*const zx.ir.Program {
        const selected = &current.payload.Selection;
        const case = &self.compiler.plan.selections[selected.item].cases[row];
        const attribute = case.label.attribute() orelse return null;

        return try self.compiler.keep(try self.compiler.value(attribute, selected.subject.output_type, false));
    }
    pub fn refineCase(self: *Host, current: *Frame, row: usize) Compiler.Error!void {
        const compiler = self.compiler;
        const selected = &current.payload.Selection;
        const present = compiler.plan.selections[selected.item].cases[row].truth orelse return;

        const scope: condition.Scope = .{
            .allocator = compiler.allocator,
            .bindings = compiler.bindings.items(.name),
            .facts = &compiler.nonnull,
        };

        condition.assumeParsed(compiler.allocator, &selected.parsed, present, scope) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFlow,
        };
    }
    pub fn pushCase(self: *Host, current: *Frame, first: usize, bindings: usize, facts: usize, label: ?*const zx.ir.Program) Compiler.Error!void {
        const compiler = self.compiler;
        const selected = &current.payload.Selection;
        const case = &compiler.plan.selections[selected.item].cases[first];
        const destination = current.body.first + @as(u32, @intCast(first));
        const range = try Body.reserve(compiler, case.body);
        const child = try self.stack.addOne(self.memory);

        child.* = .{ .cursor = Cursor.body(case.body), .destination = destination, .body = range, .payload = .{
            .Case = .{ .bindings = bindings, .facts = facts, .label = label },
        } };
    }

    pub fn closeTask(self: *Host, parallel_task: bool) Compiler.Error!void {
        if (parallel_task) unreachable;

        var output: Compiler.TaskOutput = undefined;
        const bindings = self.frame().payload.Task.bindings;

        if (try self.prepareTaskOutput(&output)) try self.evaluateTaskOutput(&output, self.compiler.seedResult());

        self.compiler.bindings.len = bindings;

        const visible = try output.publish(self.compiler);

        self.compiler.compiled.steps.set(self.frame().destination, .{
            .kind = .Task,
            .first = output.body,
            .output = if (visible) |binds| (if (binds) .Constant else .Evaluate) else .None,
            .value = output.value,
            .name = output.name(),
        });
    }

    pub fn prepareTaskOutput(self: *Host, output: *Compiler.TaskOutput) Compiler.Error!bool {
        const frame_ = self.frame();
        const compiler = self.compiler;
        const body = try frame_.body.close(compiler, false);

        output.* = .{ .body = body };

        return compiler.plan.tasks[frame_.payload.Task.item].output != null;
    }

    pub fn evaluateTaskOutput(self: *Host, output: *Compiler.TaskOutput, binding: Compiler.Result) Compiler.Error!void {
        const compiler = self.compiler;

        try output.evaluate(compiler, compiler.plan.tasks[self.frame().payload.Task.item].output.?.*, binding);
    }
    pub fn mergeParallelBindings(self: *Host) std.mem.Allocator.Error!void {
        const compiler = self.compiler;

        try zx.columns.appendRows(&compiler.bindings, compiler.binding_allocator, self.frame().payload.Parallel.slice(), 0);
    }

    pub fn closeParallel(self: *Host) Compiler.Error!void {
        const compiler = self.compiler;
        const current = self.frame();

        try self.mergeParallelBindings();

        compiler.compiled.steps.set(current.destination, .{ .kind = .Parallel, .first = current.body.first, .count = current.body.count });
    }

    pub fn closeSelection(self: *Host) Compiler.Error!void {
        const compiler = self.compiler;
        const current = self.frame();
        const selected = &current.payload.Selection;
        const exhaustive = try self.checkSelection();

        compiler.compiled.steps.set(current.destination, .{
            .kind = .Selection,
            .first = current.body.first,
            .count = current.body.count,
            .value = selected.subject,
            .exhaustive = exhaustive,
        });
    }

    pub fn checkSelection(self: *Host) Compiler.Error!bool {
        const compiler = self.compiler;
        const current = self.frame();
        const selected = &current.payload.Selection;
        const plan = &compiler.plan.selections[selected.item];
        const labels = compiler.compiled.cases.items(.value)[current.body.first..][0..current.body.count];
        const checked = try @import("../selection.zig").check(compiler.allocator, compiler.types, selected.subject, plan.subject.*, labels, plan.cases);

        if (checked == .exhaustive) return checked.exhaustive;

        compiler.issue = checked.diagnostic;

        return error.InvalidFlow;
    }
    pub fn publishCase(self: *Host, row: u32) std.mem.Allocator.Error!void {
        const current = self.frame();
        const body = try current.body.close(self.compiler, true);

        self.compiler.compiled.cases.set(row, .{ .value = current.payload.Case.label, .body = body });
    }

    pub fn closeCase(self: *Host) Compiler.Error!void {
        const compiler = self.compiler;
        const current = self.frame();
        const saved = current.payload.Case;

        try self.publishCase(current.destination);

        compiler.nonnull.shrinkRetainingCapacity(saved.facts);

        compiler.bindings.len = saved.bindings;
    }
};

pub fn run(compiler: *Compiler, body: Prepared.Unit) Compiler.Error!u32 {
    var buffer: [inline_frames]Frame = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(std.mem.asBytes(&buffer), compiler.binding_allocator);

    var state: Host = .{
        .compiler = compiler,
        .root = .{ .cursor = Cursor.body(body), .body = try Body.reserve(compiler, body), .payload = .Root },
        .memory = scratch.allocator(),
    };

    defer {
        while (state.stack.items.len != 0) state.pop();

        state.stack.deinit(state.memory);
    }

    try traversal.run(&state, compiler.plan);

    return state.root.body.close(compiler, true);
}
