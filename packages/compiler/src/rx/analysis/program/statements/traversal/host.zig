const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Statements = @import("../../statements.zig");
const Plan = @import("../../control/plan.zig");
const Writer = @import("../../control/writer.zig");
const Invocation = @import("../invocation.zig");
const inlineValue = @import("../../expression.zig").inlineValue;
const Error = Statements.Error;
const request = @import("../traversal.zig").Input;
const Control = std.meta.Child(@FieldType(request, "control"));
const Cursor = std.meta.Child(@FieldType(Control, "writer"));

const Scope = struct {
    bindings: u64,
    value: ?u32,
};

pub const State = struct {
    statements: *const Statements,
    allocator: std.mem.Allocator,
    root: u32,
    root_writer: *Writer.Cursor,
    scope_counts: []u64 = &.{},
    scope_values: []?u32 = &.{},
    writers: []Writer.Cursor = undefined,
    row: *const Plan.Row = undefined,
    writer: *Writer.Cursor = undefined,
    call: Invocation = undefined,
    call_binding_count: usize = undefined,
    control: Control = undefined,
    view: Cursor = undefined,
    cells: []u32 = undefined,
    pub fn initControl(self: *State, layout: []const u32) void {
        const statements = self.statements;
        const table = &statements.writer.columns;

        self.view = .{ .parallel_symbols = @ptrCast(&table.parallel_symbols.items), .cells = @ptrCast(&self.cells) };

        self.control = .{
            .writer = &self.view,
            .layout = layout,
            .firsts = table.block_first.items,
            .lengths = table.block_count.items,
        };
    }
    pub fn commit(self: *State, effect: anytype) Error!void {
        const statements = self.statements;
        const writer = statements.writer;

        if (effect.bindings) |bindings| {
            const builder = statements.builder;

            try builder.bindings.ensureUnusedCapacity(builder.allocator, bindings.len);
            for (bindings) |symbol| builder.bindings.appendAssumeCapacity(@fromBackingInt(symbol));
        }

        if (effect.statement) |statement| writer.commit(self.writer, statement);

        if (effect.member) |item| {
            const symbol: ?ir.SymbolId = if (item.symbol) |id| @fromBackingInt(id) else null;

            writer.parallelBranch(item.position, symbol, @fromBackingInt(item.value));
        }

        if (effect.case_member) |item| writer.commitCase(item.position, item.block, item.label);

        if (effect.scope) |scope| {
            self.scope_counts[scope.slot] = scope.bindings;
            self.scope_values[scope.slot] = scope.value;
        }

        if (effect.restore) |count| statements.restoreBindings(@intCast(count));
        if (effect.binding) |symbol| try statements.publishBinding(@fromBackingInt(symbol));
    }

    pub fn borrow(handle: *anyopaque) *State {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn reserveBodyStatements(handle: *anyopaque, slots: u64) Error!void {
    const state = State.borrow(handle);
    var scopes: std.MultiArrayList(Scope) = .empty;

    try scopes.setCapacity(state.allocator, @intCast(slots));

    scopes.len = @intCast(slots);
    state.scope_counts = scopes.items(.bindings);
    state.scope_values = scopes.items(.value);
    state.writers = try state.allocator.alloc(Writer.Cursor, state.statements.plan.rows[state.root].tag);
}

pub fn selectBodyWriter(handle: *anyopaque, block: u32) void {
    const state = State.borrow(handle);

    state.row = &state.statements.plan.rows[block];
    state.writer = if (block == state.root) state.root_writer else &state.writers[state.row.tag];
    state.cells = state.writer.cells();
}

pub fn evaluateBodyValue(handle: *anyopaque, row: u32, borrowed: bool) Error!u32 {
    return @backingInt(try State.borrow(handle).statements.evaluateValue(row, borrowed));
}

pub fn defineBodyTaskBinding(handle: *anyopaque, row: u32, value: u32) Error!u32 {
    const state = State.borrow(handle);

    return @backingInt(try state.statements.taskSymbol(row, @fromBackingInt(value)));
}

pub fn publishBodyBinding(handle: *anyopaque, symbol: u32) Error!void {
    try State.borrow(handle).statements.publishBinding(@fromBackingInt(symbol));
}

pub fn evaluateBodyCaseLabel(handle: *anyopaque, row: u32) Error!?u32 {
    const state = State.borrow(handle);
    const program = state.statements.flow.cases.items(.value)[row] orelse return null;

    return @backingInt(try inlineValue(state.statements.builder, program.*, false));
}

pub fn initializeBodyCase(handle: *anyopaque) void {
    const state = State.borrow(handle);

    state.writer.* = Writer.Cursor.init(state.row.first);
}

pub fn requireBodyBlock(valid: bool) error{InvalidModule}!void {
    if (!valid) return error.InvalidModule;
}
