const std = @import("std");
const ir = @import("zx").ir;
const Statements = @import("../../statements.zig");
const Writer = @import("../../control/writer.zig");
const Frame = @import("../traversal.zig").Frame;
const inlineValue = @import("../../expression.zig").inlineValue;
const generated = @import("generated_rx_statement_frames");
const Input = std.meta.Child(generated.Input);
pub const Shape = std.meta.Child(@FieldType(Input, "shape"));
pub const Region = enum(u8) { Root, Task, Selection, Case };
const Snapshot = enum(usize) { status, position, end, scope_step, case_first };

const Status = enum(u8) {
    advancing,
    done,
    out_of_memory,
    invalid_module,
    unreachable_flow,
    incomplete_flow,
    fn failure(err: Statements.Error) u8 {
        return @backingInt(switch (err) {
            error.OutOfMemory => Status.out_of_memory,
            error.InvalidModule => Status.invalid_module,
            error.UnreachableFlow => Status.unreachable_flow,
            error.IncompleteFlow => Status.incomplete_flow,
        });
    }
    fn code(result: Statements.Error!void) u8 {
        result catch |err| return failure(err);

        return @backingInt(Status.advancing);
    }
};

pub fn run(statements: *const Statements, root: *Frame, writer: *Writer.Cursor, stack: *std.ArrayList(Frame), temporary: std.mem.Allocator, shape: *const Shape) Statements.Error!void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    var state: Context = .{
        .statements = statements,
        .root = root,
        .root_writer = writer,
        .stack = stack,
        .temporary = temporary,
    };

    var words: [@typeInfo(Snapshot).@"enum".field_names.len]u64 = @splat(0);
    const cursor: []u64 = &words;

    const request: Input = .{
        .context = @ptrCast(&state),
        .shape = shape,
        .borrow_root = statements.retain_metadata,
        .cursor = @ptrCast(&cursor),
        .snapshot_target = @ptrCast(&cursor),
    };

    const code = generated.executeIn(empty.allocator(), &request) catch return error.InvalidModule;

    return switch (@as(Status, @fromBackingInt(@intCast(code)))) {
        .done => {},
        .out_of_memory => error.OutOfMemory,
        .unreachable_flow => error.UnreachableFlow,
        .incomplete_flow => error.IncompleteFlow,
        .advancing, .invalid_module => error.InvalidModule,
    };
}

const Context = struct {
    statements: *const Statements,
    root: *Frame,
    root_writer: *Writer.Cursor,
    stack: *std.ArrayList(Frame),
    temporary: std.mem.Allocator,
    task_value: ir.ExprId = @fromBackingInt(0),
    task_symbol: ir.SymbolId = @fromBackingInt(0),
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn active(self: *const @This()) *Frame {
        const frames = self.stack.items;

        return if (frames.len == 0) self.root else &frames[frames.len - 1];
    }
    fn writer(self: *const @This(), frame: *const Frame) *Writer.Cursor {
        return if (frame.block) |index| &self.stack.items[index].scope.Case.writer else self.root_writer;
    }
    fn push(self: *@This(), position: u64, first: u32, count: u32, scope: @FieldType(Frame, "scope")) Statements.Error!void {
        const block = if (scope == .Case) self.stack.items.len else self.active().block;

        try self.stack.append(self.temporary, .{
            .cursor = .range(first, count),
            .block = block,
            .step = @intCast(position),
            .scope = scope,
        });
    }
};

const Effects = struct {
    pub fn inspect(handle: *const anyopaque, target: *const anyopaque) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const words: *const []u64 = @ptrCast(@alignCast(target));
        const current = state.active();
        const writer = state.writer(current);

        words.*[@backingInt(Snapshot.position)] = current.cursor.position;
        words.*[@backingInt(Snapshot.end)] = current.cursor.end;
        words.*[@backingInt(Snapshot.scope_step)] = current.step;
        words.*[@backingInt(Snapshot.case_first)] = writer.counts.cases;

        return @backingInt(std.meta.activeTag(current.scope));
    }

    pub fn seek(handle: *const anyopaque, next: u64) callconv(.c) void {
        Context.borrow(handle).active().cursor.position = @intCast(next);
    }

    pub fn writeCalls(handle: *const anyopaque, position: u64, end: u64) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;
        const writer = state.writer(state.active());
        const rows = self.flow.steps.items(.first)[@intCast(position)..@intCast(end)];

        for (rows) |row| self.call(writer, &self.calls[row]) catch |err| return Status.failure(err);

        return @backingInt(Status.advancing);
    }

    pub fn writeParallel(handle: *const anyopaque, first: u32, count: u32) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;

        return Status.code(self.parallel(state.writer(state.active()), self.calls[first..][0..count]));
    }

    pub fn writeReturn(handle: *const anyopaque, position: u64, borrowed: bool) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;
        const program = self.flow.steps.items(.value)[@intCast(position)].?;
        const value = inlineValue(self.builder, program.*, borrowed) catch |err| return Status.failure(err);

        self.writer.result(state.writer(state.active()), value);

        return @backingInt(Status.advancing);
    }

    pub fn pushTask(handle: *const anyopaque, position: u64, first: u32, count: u32) callconv(.c) u8 {
        const state = Context.borrow(handle);

        return Status.code(state.push(position, first, count, .{ .Task = state.statements.builder.bindings.items.len }));
    }
    pub fn pushSelection(handle: *const anyopaque, position: u64, first: u32, count: u32) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;
        const program = self.flow.steps.items(.value)[@intCast(position)].?;
        const subject = inlineValue(self.builder, program.*, false) catch |err| return Status.failure(err);

        return Status.code(state.push(position, first, count, .{ .Selection = subject }));
    }
    pub fn pushCase(handle: *const anyopaque, position: u64, first: u32, count: u32, unit: u32, target: u32) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;

        const label = if (self.flow.cases.items(.value)[@intCast(position)]) |program|
            inlineValue(self.builder, program.*, false) catch |err| return Status.failure(err)

        else
            null;

        return Status.code(state.push(position, first, count, .{ .Case = .{
            .unit = unit,
            .target = target,
            .label = label,
            .bindings = self.builder.bindings.items.len,
            .writer = Writer.Cursor.init(self.plan.rows[unit].first),
        } }));
    }

    pub fn writeCase(handle: *const anyopaque) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;
        const current = state.active();
        const branch = &current.scope.Case;
        const row = self.plan.rows[branch.unit];

        return Status.code(self.writer.finishCase(state.writer(current), row.tag, self.plan.end(branch.unit), branch.target, branch.label));
    }

    pub fn writeSelection(handle: *const anyopaque, count: u32, exhaustive: bool) callconv(.c) void {
        const state = Context.borrow(handle);
        const current = state.active();

        state.statements.writer.selection(state.writer(current), current.scope.Selection, count, exhaustive);
    }

    pub fn evaluateTask(handle: *const anyopaque) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;
        const program = self.flow.steps.items(.value)[state.active().step].?;

        state.task_value = inlineValue(self.builder, program.*, false) catch |err| return Status.failure(err);

        return @backingInt(Status.advancing);
    }

    pub fn writeTaskEvaluation(handle: *const anyopaque) callconv(.c) void {
        const state = Context.borrow(handle);

        state.statements.writer.evaluate(state.writer(state.active()), state.task_value);
    }

    pub fn defineTaskBinding(handle: *const anyopaque) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const self = state.statements;
        const value = state.task_value;
        const current = state.active();
        const name = self.flow.steps.items(.name)[current.step].?;
        const builder = self.builder;

        state.task_symbol = builder.symbol(name, builder.expressionType(value), builder.expressionSpan(value)) catch |err| return Status.failure(err);

        self.writer.constant(state.writer(current), state.task_symbol, value);

        return @backingInt(Status.advancing);
    }

    pub fn publishTaskBinding(handle: *const anyopaque) callconv(.c) u8 {
        const state = Context.borrow(handle);
        const builder = state.statements.builder;

        return Status.code(builder.bindings.append(builder.allocator, state.task_symbol));
    }

    pub fn restoreScope(handle: *const anyopaque) callconv(.c) void {
        const state = Context.borrow(handle);

        const count = switch (state.active().scope) {
            .Task => |bindings| bindings,
            .Case => |branch| branch.bindings,
            else => unreachable,
        };

        state.statements.builder.bindings.shrinkRetainingCapacity(count);
    }

    pub fn pop(handle: *const anyopaque) callconv(.c) void {
        _ = Context.borrow(handle).stack.pop();
    }
};

comptime {
    for ([_][]const u8{
        "inspect",
        "seek",
        "writeCalls",
        "writeParallel",
        "writeReturn",
        "pushTask",
        "pushSelection",
        "pushCase",
        "writeCase",
        "writeSelection",
        "evaluateTask",
        "writeTaskEvaluation",
        "defineTaskBinding",
        "publishTaskBinding",
        "restoreScope",
        "pop",
    }) |name| {
        @export(&@field(Effects, name), .{ .name = "zxcRxStatement_" ++ name });
    }
}
