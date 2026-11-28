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
const Api = @import("../../expressions/evaluate.zig").Api;
const StatementStack = Api.StatementStack;
const Registered = @import("../../value_call/locals.zig").Registered;
const Binding = @FieldType(Lower, "cache").Binding;
const Selection = std.meta.Child(@FieldType(execute.zx_pending, "store_0"));

const StoreHost = struct {
    lowering: *Lower,
    stack: []Binding,
    count: usize = 0,
    store_0: *Selection,
    pub fn commit(self: *StoreHost, pending: anytype) Lower.Error!void {
        const next = pending.store_0 orelse return;

        if (next.reference) |value| {
            self.stack[self.count] = try self.lowering.cache.bind(
                self.lowering.allocator,
                @fromBackingInt(next.subject),
                @fromBackingInt(value),
            );

            self.count += 1;
        } else {
            self.pop();
        }

        self.store_0.* = next;
    }

    fn pop(self: *StoreHost) void {
        self.count -= 1;

        self.stack[self.count].restore();
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

    const stack = try scratch.alloc(Binding, @intCast(plan.selection_depth));
    var store: Selection = &.{ .subject = 0, .reference = null };
    var host: StoreHost = .{ .lowering = self, .stack = stack, .store_0 = &store };

    errdefer while (host.count != 0) host.pop();

    const Execution = std.meta.Child(execute.Input);
    const Schedule = std.meta.Child(@FieldType(Execution, "plan"));
    const Context = std.meta.Child(@FieldType(Execution, "context"));
    const Control = std.meta.Child(@FieldType(Context, "control"));
    const Expressions = std.meta.Child(@FieldType(Context, "expressions"));
    const Types = std.meta.Child(@FieldType(Context, "types"));
    const control = zx.columns.borrow(Control, control_source);
    const expressions = zx.columns.borrow(Expressions, @as(*const ir.ExpressionTable, &self.program.expressions));
    const types = ir.TypeTable.borrow(Types, self.program.types);
    const schedule = zx.columns.view(Schedule, plan);

    const context: Context = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(&sequence),
        .control = &control,
        .expressions = &expressions,
        .types = &types,
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

pub fn openStatementScope(allocator: std.mem.Allocator, handle: *anyopaque, first: u32, count: u32) Lower.Error!*const StatementStack {
    const self = @import("../../expressions/evaluate.zig").borrow(handle);
    const result = try allocator.create(StatementStack);

    const registered: Registered = if (count != 0)
        try @import("../../value_call/locals.zig").register(self, .{ .control = self.program.body.control, .first = first, .len = count })

    else
        .{ .state = self.state_symbols.checkpoint(), .stack = self.stack_symbols.checkpoint() };

    const stack = self.stack_symbols.current();

    result.* = .{
        .state_checkpoint = registered.state,
        .stack_checkpoint = registered.stack,
        .stack_keys = stack.keys.items,
        .stack_buckets = stack.buckets.items,
    };

    return result;
}

pub fn finishStatementScope(handle: *anyopaque, state_checkpoint: u64, stack_checkpoint: u64, spans: []const u64) Lower.Error!u64 {
    const self = @import("../../expressions/evaluate.zig").borrow(handle);
    const saved: Registered = .{ .state = state_checkpoint, .stack = stack_checkpoint };

    defer saved.release(self);

    if (spans.len == 0) return 0;

    return rows.packSpan(try @import("../../../node/blocks.zig").joinStatementSpans(
        self.allocator,
        self.builder.nodes,
        spans,
        false,
    ));
}

pub fn finishStatementSelection(
    allocator: std.mem.Allocator,
    handle: *anyopaque,
    name: []const u8,
    subject: u32,
    reference: u32,
    selected: bool,
    exhaustive: bool,
    total_count: u64,
    fallback: ?u64,
    cases: *const Api.StatementCases,
) Lower.Error!u64 {
    const self = @import("../../expressions/evaluate.zig").borrow(handle);

    return rows.packSpan(try @import("../switch/publish.zig").lower(self, .{
        .name = name,
        .subject = subject,
        .reference = reference,
        .selected = selected,
        .exhaustive = exhaustive,
        .total_count = total_count,
        .fallback = if (fallback) |span| rows.unpackSpan(span) else null,
        .cases = cases,
    }, allocator));
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
