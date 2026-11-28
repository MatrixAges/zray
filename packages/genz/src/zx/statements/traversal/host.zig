const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const rows = @import("../../construction/publication.zig");
const entry = @import("generated_statement_traversal");
const execute = @import("generated_execute_statement_traversal");
const Input = std.meta.Child(entry.Input);
const Rows = std.meta.Child(@FieldType(Input, "rows"));
const Registered = @import("../../value_call/locals.zig").Registered;
const Binding = @FieldType(Lower, "cache").Binding;

fn Store(comptime field: []const u8) type {
    return std.meta.Child(@FieldType(execute.zx_pending, field));
}

const StoreHost = struct {
    lowering: *Lower,
    selections: []Binding,
    selection_count: usize = 0,
    scopes: []Registered,
    scope_count: usize = 0,
    locals_view: std.meta.Child(Store("store_0")) = undefined,
    store_0: *Store("store_0"),
    store_1: *Store("store_1"),
    store_2: *Store("store_2"),
    pub fn commit(self: *StoreHost, pending: anytype) Lower.Error!void {
        if (pending.store_0) |next| {
            if (next.open) {
                try self.openScope(next);
            } else {
                self.scope_count -= 1;

                self.scopes[self.scope_count].release(self.lowering);

                self.store_0.* = next;
            }
        }

        if (pending.store_1) |next| {
            self.lowering.uses_context = self.lowering.uses_context or next.uses_context;
            self.lowering.uses_parallel = self.lowering.uses_parallel or next.uses_parallel;
            self.lowering.uses_allocator = self.lowering.uses_allocator or next.uses_parallel;
            self.store_1.* = next;
        }

        if (pending.store_2) |next| {
            if (next.reference) |value| {
                self.selections[self.selection_count] = try self.lowering.cache.bind(
                    self.lowering.allocator,
                    @fromBackingInt(next.subject),
                    @fromBackingInt(value),
                );

                self.selection_count += 1;
            } else {
                self.popSelection();
            }

            self.store_2.* = next;
        }
    }
    fn openScope(self: *StoreHost, next: Store("store_0")) Lower.Error!void {
        const lowering = self.lowering;

        const registered: Registered = if (next.count != 0)
            try @import("../../value_call/locals.zig").register(lowering, .{
                .control = lowering.program.body.control,
                .first = next.first,
                .len = next.count,
            })

        else
            .{ .state = lowering.state_symbols.checkpoint(), .stack = lowering.stack_symbols.checkpoint() };

        self.scopes[self.scope_count] = registered;
        self.scope_count += 1;

        const stack = lowering.stack_symbols.current();

        self.locals_view = next.*;
        self.locals_view.keys = stack.keys.items;
        self.locals_view.buckets = stack.buckets.items;
        self.store_0.* = &self.locals_view;
    }

    fn popSelection(self: *StoreHost) void {
        self.selection_count -= 1;

        self.selections[self.selection_count].restore();
    }
};

pub fn lower(self: *Lower, values: ir.Block) Lower.Error!node.Block {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var inline_memory: [4096]u8 = undefined;
    var buffer = std.heap.BufferFirstAllocator.init(&inline_memory, arena.allocator());

    defer arena.deinit();

    const scratch = buffer.allocator();
    const control_source: *const zx.ir.ControlTable = values.control;
    const row_inputs = zx.columns.borrow(Rows, control_source);
    const input: Input = .{ .rows = &row_inputs, .first = values.first, .count = values.len };
    const plan = zx.columns.invoke(entry.executeValue, scratch, &input) catch |err| return failure(err);
    var sequence = self.builder.statementSequence(self.workspace);

    defer sequence.deinit();

    const baseline: Registered = .{
        .state = self.state_symbols.checkpoint(),
        .stack = self.stack_symbols.checkpoint(),
    };

    errdefer baseline.release(self);

    const selections = try scratch.alloc(Binding, @intCast(plan.selection_depth));
    const scopes = try scratch.alloc(Registered, @intCast(plan.depth));
    var locals: Store("store_0") = &.{ .open = false, .first = 0, .count = 0, .keys = &.{}, .buckets = &.{} };
    var effects: Store("store_1") = &.{ .uses_context = false, .uses_parallel = false };
    var selection: Store("store_2") = &.{ .subject = 0, .reference = null };

    var host: StoreHost = .{
        .lowering = self,
        .selections = selections,
        .scopes = scopes,
        .store_0 = &locals,
        .store_1 = &effects,
        .store_2 = &selection,
    };

    errdefer while (host.selection_count != 0) host.popSelection();

    const Execution = std.meta.Child(execute.Input);
    const Schedule = std.meta.Child(@FieldType(Execution, "plan"));
    const Context = std.meta.Child(@FieldType(Execution, "context"));
    const Control = std.meta.Child(@FieldType(Context, "control"));
    const Expressions = std.meta.Child(@FieldType(Context, "expressions"));
    const Types = std.meta.Child(@FieldType(Context, "types"));
    const control = zx.columns.borrow(Control, control_source);
    const expressions = zx.columns.borrow(Expressions, @as(*const ir.ExpressionTable, &self.program.expressions));
    const types = ir.TypeTable.borrow(Types, self.program.types);
    const StoreValues = std.meta.Child(@FieldType(Context, "store_values"));
    const store_values = zx.columns.borrow(StoreValues, @as(*const ir.ExpressionTable, &self.program.expressions));
    const schedule = zx.columns.view(Schedule, plan);

    const context: Context = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(&sequence),
        .control = &control,
        .expressions = &expressions,
        .types = &types,
        .store_values = &store_values,
        .function_modes = zx.columns.slice(@FieldType(Context, "function_modes"), self.program.functions.store_modes),
        .call_arguments = self.program.expressions.call_arguments,
        .output_type = @backingInt(self.program.output_type),
        .store_mode = @fromBackingInt(@backingInt(self.program.store_mode)),
        .store_count = self.program.stores.count(),
        .names = self.names,
        .used = self.used,
        .symbol_types = self.program.symbols.types,
        .transaction = self.transaction(),
        .value_output = self.value_output,
        .state_active = self.state_active,
        .public_value_output = self.public_value_output,
    };

    const request: Execution = .{
        .context = &context,
        .plan = &schedule,
        .first = @intCast(values.first),
        .count = @intCast(values.len),
    };

    const span = (execute.executeIn(scratch, &request, &host) catch |err|
        return failure(err)) orelse return error.OutOfMemory;

    return rows.unpackSpan(span);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
