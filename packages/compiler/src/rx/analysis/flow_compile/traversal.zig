const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Compiler = @import("../flow_compile.zig");
const Flow = @import("../program/flow.zig");
const Prepared = @import("../project/flow.zig");
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
    fn close(self: Body, compiler: *Compiler, block: bool) Compiler.Error!u32 {
        return compiler.compiled.unit(compiler.binding_allocator, self.first, self.count, block);
    }
};

const Selection = struct {
    item: u32,
    parsed: frontend.ExpressionInput.Result,
    subject: *const zx.ir.Program,
    first: u32,
    count: u32,
};

const Payload = union(Region) {
    Root: void,
    Task: struct { item: u32, bindings: usize },
    ParallelTask: void,
    Parallel: struct { first: u32, count: u32, outputs: frontend.expressions.BindingStorage = .empty },
    Selection: Selection,
    Case: struct { bindings: usize, scope: Compiler.CaseScope },
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
            .Parallel => |*parallel| parallel.outputs.deinit(allocator),
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
        const compiler = self.compiler;

        if (current.payload == .Parallel) {
            for (items) |item| {
                const id = try compiler.call(item, &current.payload.Parallel.outputs);

                try compiler.checkParallelCall(item, id);
            }

            return;
        }

        for (items, current.row(first)..) |item, row| {
            const id = try compiler.call(item, &compiler.bindings);

            compiler.compiled.steps.set(row, .{ .kind = .Call, .first = id });
        }
    }

    pub fn result(self: *Host, current: *Frame, first: usize, item: u32) Compiler.Error!void {
        const compiler = self.compiler;
        const plan = compiler.plan;
        const publish = current.payload == .Root and compiler.retain_metadata;
        const value = try compiler.keep(try compiler.value(plan.results[item], compiler.output_type, publish));

        compiler.compiled.steps.set(current.row(first), .{ .kind = .Return, .value = value });

        if (publish) compiler.root_return = value;
    }

    pub fn task(self: *Host, current: *Frame, first: usize, item: u32, parallel_task: bool) Compiler.Error!void {
        const compiler = self.compiler;
        const plan = compiler.plan;

        if (parallel_task) {
            _ = try @import("../parallel_task.zig").compile(compiler, &plan.tasks[item], &current.payload.Parallel.outputs);

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

        child.* = .{ .cursor = Cursor.body(branches), .destination = destination, .payload = .{
            .Parallel = .{ .first = first_call, .count = branches.count },
        } };
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

        child.* = .{ .cursor = Cursor.cases(count), .destination = destination, .payload = .{
            .Selection = .{ .item = item, .parsed = parsed, .subject = subject, .first = cases, .count = count },
        } };
    }

    pub fn openCase(self: *Host, current: *Frame, first: usize) Compiler.Error!void {
        const compiler = self.compiler;
        const selected = &current.payload.Selection;
        const case = &compiler.plan.selections[selected.item].cases[first];
        const bindings = compiler.bindings.len;
        const scope = try compiler.enterCase(case, &selected.parsed, selected.subject.output_type);
        const destination = selected.first + @as(u32, @intCast(first));
        const range = try Body.reserve(compiler, case.body);
        const child = try self.stack.addOne(self.memory);

        child.* = .{ .cursor = Cursor.body(case.body), .destination = destination, .body = range, .payload = .{
            .Case = .{ .bindings = bindings, .scope = scope },
        } };
    }

    pub fn closeTask(self: *Host, parallel_task: bool) Compiler.Error!void {
        if (parallel_task) unreachable;

        const current = self.frame();
        const compiler = self.compiler;
        const saved = current.payload.Task;
        const body = try current.body.close(compiler, false);
        const compiled = try compiler.finishTask(&compiler.plan.tasks[saved.item], body, saved.bindings);

        compiler.compiled.steps.set(current.destination, compiled);
    }

    pub fn closeParallel(self: *Host) Compiler.Error!void {
        const compiler = self.compiler;
        const current = self.frame();
        const branches = &current.payload.Parallel;

        try zx.columns.appendRows(&compiler.bindings, compiler.binding_allocator, branches.outputs.slice(), 0);

        compiler.compiled.steps.set(current.destination, .{ .kind = .Parallel, .first = branches.first, .count = branches.count });
    }

    pub fn closeSelection(self: *Host) Compiler.Error!void {
        const compiler = self.compiler;
        const current = self.frame();
        const selected = &current.payload.Selection;
        const plan = &compiler.plan.selections[selected.item];
        const exhaustive = try compiler.checkSelection(selected.subject, plan.subject.*, plan.cases, selected.first, selected.count);

        compiler.compiled.steps.set(current.destination, .{
            .kind = .Selection,
            .first = selected.first,
            .count = selected.count,
            .value = selected.subject,
            .exhaustive = exhaustive,
        });
    }

    pub fn closeCase(self: *Host) Compiler.Error!void {
        const compiler = self.compiler;
        const current = self.frame();
        const case = current.payload.Case;
        const unit = try current.body.close(compiler, true);

        compiler.nonnull.shrinkRetainingCapacity(case.scope.facts);

        compiler.bindings.len = case.bindings;
        compiler.compiled.cases.set(current.destination, .{ .value = case.scope.label, .body = unit });
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
