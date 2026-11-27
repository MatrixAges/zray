const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Mapping = @import("../mapping.zig");
const missing = @import("../linking.zig").missing;
const symbol_link = @import("symbols.zig");
const literal_link = @import("literals/host.zig");
const headers = @import("headers.zig");
const operands = @import("operands/host.zig");
const abi = @import("abi.zig");
const Plan = std.meta.Child(@FieldType(abi.Request, "plan"));
const Error = Builder.Error;

pub const State = struct {
    builder: *Builder,
    program: *const ir.Program,
    borrow_text: bool,
    planning: bool = true,
    mapping: Mapping = undefined,
    symbols: symbol_link.Frame = .{},
    literals: literal_link.Frame = .{},
    operands: operands.Frame = .{},
    payload: abi.Payload = undefined,
    target_payloads: []u32 = undefined,
    pub fn borrow(handle: *anyopaque) *State {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(builder: *Builder, program: *const ir.Program, block: ir.Block, borrow_text: bool, allocator: std.mem.Allocator) Error!ir.ExprId {
    var state: State = .{ .builder = builder, .program = program, .borrow_text = borrow_text };
    const target = builder.symbols.view();
    const table = &program.expressions;
    const control = block.control;
    const Body = std.meta.Child(@FieldType(Plan, "body"));
    const Expressions = std.meta.Child(@FieldType(Plan, "expressions"));

    state.operands.initialize(&state);

    var input: abi.Request = .{
        .frame = @ptrCast(&state),
        .plan = &.{
            .body = &.{
                .statement_kinds = zx.columns.slice(@FieldType(Body, "statement_kinds"), control.statement_kinds[block.first..][0..block.len]),
                .statement_payloads = control.statement_payloads[block.first..][0..block.len],
                .constant_symbols = control.constant_symbols,
                .constant_values = control.constant_values,
                .results = control.results,
            },
            .expressions = &.{
                .kinds = zx.columns.slice(@FieldType(Expressions, "kinds"), table.kinds),
                .payloads = table.payloads,
                .references = table.references,
                .projection_indices = table.projection_indices,
                .projection_targets = table.projection_targets,
            },
            .scope = &.{
                .names = program.symbols.names[1..block.len],
                .types = program.symbols.types[1..block.len],
                .active = @ptrCast(builder.bindings.items),
                .target_names = target.names,
                .target_types = target.types,
            },
            .base = builder.expressions.count(),
        },
        .symbols = &state.symbols.input,
        .literals = &state.literals.input,
        .payload = &state.payload,
        .operands = &state.operands.input,
        .first = null,
    };

    const initial = (try execute(&state, allocator, &input)).initial.?;

    if (initial.symbols) |rows| try state.symbols.commit(builder, rows);
    if (initial.literals) |rows| try state.literals.commit(builder, rows);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var bytes: [4096]u8 = undefined;

    input.first = initial.first;

    while (input.first != null) {
        var scratch = std.heap.BufferFirstAllocator.init(&bytes, arena.allocator());
        const step = (try execute(&state, scratch.allocator(), &input)).step.?;

        for (step.writes) |write| state.target_payloads[write.index] = write.value;
        if (step.patch) |patch| try state.operands.commit(builder, patch);
        if (step.operand) |operand| state.target_payloads[operand.index] = operand.value;

        input.first = step.next;
        _ = arena.reset(.retain_capacity);
    }

    headers.commit(&builder.expressions, table, initial.ranges, @intCast(initial.count));

    return @fromBackingInt(initial.returned);
}

fn execute(state: *const State, allocator: std.mem.Allocator, input: *const abi.Request) Error!abi.Output {
    return zx.columns.invoke(abi.entry.executeValue, allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow, error.IntegerOverflow => if (state.planning) error.OutOfMemory else error.InvalidModule,
        error.IndexOutOfBounds, error.InvalidModule => error.InvalidModule,
        else => unreachable,
    };
}

pub fn reserveExpressionLink(handle: *anyopaque, returned: ?u32, rows: []const u32, bindings: []const u32, count: u64) Error!u32 {
    const result = returned orelse return error.InvalidModule;

    if (result == missing) return error.InvalidModule;

    const state = State.borrow(handle);
    const builder = state.builder;
    const storage = &builder.expressions;
    const source = &state.program.expressions;
    const base = storage.count();
    const length: usize = @intCast(count);
    state.planning = false;

    try storage.reserveHeaders(builder.allocator, length);

    state.mapping = .{
        .bindings = bindings,
        .locals_base = builder.symbols.count(),
        .symbol_count = state.program.symbols.count(),
        .expressions = rows,
    };

    state.target_payloads = storage.payloads.unusedCapacitySlice()[0..length];

    state.payload = .{
        .kinds = zx.columns.slice(@FieldType(abi.Payload, "kinds"), source.kinds),
        .payloads = source.payloads,
        .rows = rows,
        .literals = &state.literals.bases,
        .base = base,
    };

    return result;
}

pub fn prepareLinkSymbols(handle: *anyopaque) Error!bool {
    const state = State.borrow(handle);

    return state.symbols.prepare(state.builder, &state.program.symbols, state.mapping.bindings.len + 1, state.borrow_text);
}

pub fn prepareLinkLiterals(handle: *anyopaque) Error!bool {
    const state = State.borrow(handle);

    return state.literals.prepare(state.builder, &state.program.expressions, state.borrow_text);
}
