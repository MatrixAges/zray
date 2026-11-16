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

pub fn run(compiler: *Compiler, body: Prepared.Unit) Compiler.Error!u32 {
    const allocator = compiler.binding_allocator;
    const plan = compiler.plan;
    var buffer: [@sizeOf(Frame) * inline_frames]u8 align(@alignOf(Frame)) = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    const frame_memory = scratch.allocator();
    var stack: std.ArrayList(Frame) = .empty;
    var root: Frame = .{ .cursor = Cursor.body(body), .body = try Body.reserve(compiler, body), .payload = .Root };

    defer {
        while (stack.pop()) |frame| {
            var closing = frame;

            closing.release(allocator);
        }

        stack.deinit(frame_memory);
    }

    while (true) {
        const frame = if (stack.items.len == 0) &root else &stack.items[stack.items.len - 1];
        const region = std.meta.activeTag(frame.payload);
        const first = frame.cursor.first;
        const event = frame.cursor.advance(region, plan);

        switch (event.action) {
            .Done => return frame.body.close(compiler, true),
            .Calls => if (region == .Parallel) {
                for (event.items) |item| {
                    const id = try compiler.call(compiler.loaded[item], &frame.payload.Parallel.outputs);

                    try compiler.checkParallelCall(item, id);
                }
            } else {
                for (event.items, frame.row(first)..) |item, row| {
                    const id = try compiler.call(compiler.loaded[item], &compiler.bindings);

                    compiler.compiled.steps.set(row, .{ .kind = .Call, .first = id });
                }
            },
            .Return => {
                const value = try compiler.value(plan.results[event.items[0]], compiler.output_type, region == .Root and compiler.retain_metadata);

                compiler.compiled.steps.set(frame.row(first), .{ .kind = .Return, .value = try compiler.keep(value) });
            },
            .OpenTask => {
                const item = event.items[0];
                const unit = plan.tasks[item].body;
                const destination = frame.row(first);
                const range = try Body.reserve(compiler, unit);
                const child = try stack.addOne(frame_memory);

                child.* = .{ .cursor = Cursor.body(unit), .destination = destination, .body = range, .payload = .{
                    .Task = .{ .item = item, .bindings = compiler.bindings.len },
                } };
            },
            .OpenParallelTask => _ = try @import("../parallel_task.zig").compile(compiler, &plan.tasks[event.items[0]], &frame.payload.Parallel.outputs),
            .OpenParallel => {
                const branches = plan.groups[event.items[0]];
                const destination = frame.row(first);
                const first_call = try Flow.index(compiler.calls.items.len);
                const child = try stack.addOne(frame_memory);

                child.* = .{ .cursor = Cursor.body(branches), .destination = destination, .payload = .{
                    .Parallel = .{ .first = first_call, .count = branches.count },
                } };
            },
            .OpenSelection => {
                const item = event.items[0];
                const selection = &plan.selections[item];
                const destination = frame.row(first);
                var parsed = try @import("../attribute.zig").parseBorrowed(compiler.scratch, selection.subject.*, compiler.owner);

                errdefer parsed.deinit();

                const subject = try compiler.keep(try compiler.valueParsed(&parsed, selection.subject.*, null, false));
                const count = try Flow.index(selection.cases.len);
                const cases = try compiler.compiled.reserveCases(allocator, count);
                const child = try stack.addOne(frame_memory);

                child.* = .{ .cursor = Cursor.cases(count), .destination = destination, .payload = .{
                    .Selection = .{ .item = item, .parsed = parsed, .subject = subject, .first = cases, .count = count },
                } };
            },
            .OpenCase => {
                const selection = &frame.payload.Selection;
                const case = &plan.selections[selection.item].cases[first];
                const bindings = compiler.bindings.len;
                const scope = try compiler.enterCase(case, &selection.parsed, selection.subject.output_type);
                const destination = selection.first + @as(u32, @intCast(first));
                const range = try Body.reserve(compiler, case.body);
                const child = try stack.addOne(frame_memory);

                child.* = .{ .cursor = Cursor.body(case.body), .destination = destination, .body = range, .payload = .{
                    .Case = .{ .bindings = bindings, .scope = scope },
                } };
            },
            .CloseTask => {
                const task = frame.payload.Task;
                const compiled = try compiler.finishTask(&plan.tasks[task.item], try frame.body.close(compiler, false), task.bindings);

                compiler.compiled.steps.set(frame.destination, compiled);

                _ = stack.pop();
            },
            .CloseParallelTask => unreachable,
            .CloseParallel => {
                const parallel = &frame.payload.Parallel;

                try zx.columns.appendRows(&compiler.bindings, allocator, parallel.outputs.slice(), 0);

                compiler.compiled.steps.set(frame.destination, .{ .kind = .Parallel, .first = parallel.first, .count = parallel.count });
                frame.release(allocator);

                _ = stack.pop();
            },
            .CloseSelection => {
                const selection = &frame.payload.Selection;
                const selected = &plan.selections[selection.item];
                const exhaustive = try compiler.checkSelection(selection.subject, selected.subject.*, selected.cases, selection.first, selection.count);

                compiler.compiled.steps.set(frame.destination, .{
                    .kind = .Selection,
                    .first = selection.first,
                    .count = selection.count,
                    .value = selection.subject,
                    .exhaustive = exhaustive,
                });

                frame.release(allocator);

                _ = stack.pop();
            },
            .CloseCase => {
                const case = frame.payload.Case;
                const unit = try frame.body.close(compiler, true);

                compiler.nonnull.shrinkRetainingCapacity(case.scope.facts);

                compiler.bindings.len = case.bindings;
                compiler.compiled.cases.set(frame.destination, .{ .value = case.scope.label, .body = unit });

                _ = stack.pop();
            },
        }
    }
}
