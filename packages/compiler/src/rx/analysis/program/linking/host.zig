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
const Header = std.meta.Child(@FieldType(abi.Request, "headers"));
const Error = Builder.Error;
const batch_size = 16;

pub const State = struct {
    builder: *Builder,
    program: *const ir.Program,
    borrow_text: bool,
    planning: bool = true,
    count: usize = undefined,
    mapping: Mapping = undefined,
    symbols: symbol_link.Frame = .{},
    literals: literal_link.Frame = .{},
    operands: operands.Frame = .{},
    payload: abi.Payload = undefined,
    header: Header = undefined,
    pending_rows: [batch_size]u32 = undefined,
    pending_kinds: [batch_size]u8 = undefined,
    row_view: []u32 = undefined,
    kind_view: []u8 = undefined,
    target_payloads: []u32 = undefined,
    header_views: [4][]u8 = undefined,
    pub fn borrow(handle: *const anyopaque) *State {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(builder: *Builder, program: *const ir.Program, block: ir.Block, borrow_text: bool, allocator: std.mem.Allocator) Error!ir.ExprId {
    var state: State = .{ .builder = builder, .program = program, .borrow_text = borrow_text };
    const target = builder.symbols.view();
    const table = &program.expressions;
    const control = block.control;
    const Body = std.meta.Child(@FieldType(Plan, "body"));
    const Expressions = std.meta.Child(@FieldType(Plan, "expressions"));

    const input: abi.Request = .{
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
        .headers = &state.header,
    };

    const result = abi.entry.executeValue(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow, error.IntegerOverflow => return if (state.planning) error.OutOfMemory else error.InvalidModule,
        error.IndexOutOfBounds, error.InvalidModule => return error.InvalidModule,
        else => unreachable,
    };

    return @fromBackingInt(result);
}

pub fn reserveExpressionLink(handle: *const anyopaque, returned: ?u32, rows: []const u32, bindings: []const u32, count: u64) Error!u32 {
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

    state.count = length;

    state.mapping = .{
        .bindings = bindings,
        .locals_base = builder.symbols.count(),
        .symbol_count = state.program.symbols.count(),
        .expressions = rows,
    };

    state.row_view = &state.pending_rows;
    state.kind_view = &state.pending_kinds;
    const tail = headers.Tail.init(storage, length);

    state.target_payloads = tail.payloads;

    state.payload = .{
        .kinds = zx.columns.slice(@FieldType(abi.Payload, "kinds"), source.kinds),
        .payloads = source.payloads,
        .rows = rows,
        .literals = &state.literals.bases,
        .base = base,
        .limit = batch_size,
        .target = @ptrCast(&state.target_payloads),
        .pending_rows = @ptrCast(&state.row_view),
        .pending_kinds = @ptrCast(&state.kind_view),
    };

    state.header_views = .{
        tail.kinds,
        std.mem.sliceAsBytes(tail.types),
        std.mem.sliceAsBytes(tail.starts),
        std.mem.sliceAsBytes(tail.ends),
    };

    state.header = .{
        .rows = rows,
        .kinds = std.mem.sliceAsBytes(source.kinds),
        .types = std.mem.sliceAsBytes(source.types),
        .starts = std.mem.sliceAsBytes(source.span_start),
        .ends = std.mem.sliceAsBytes(source.span_end),
        .target_kinds = @ptrCast(&state.header_views[0]),
        .target_types = @ptrCast(&state.header_views[1]),
        .target_starts = @ptrCast(&state.header_views[2]),
        .target_ends = @ptrCast(&state.header_views[3]),
        .type_width = @sizeOf(u32),
        .span_width = @sizeOf(u64),
    };

    return result;
}

pub fn prepareLinkSymbols(handle: *const anyopaque) Error!bool {
    const state = State.borrow(handle);

    return state.symbols.prepare(state.builder, &state.program.symbols, state.mapping.bindings.len + 1, state.borrow_text);
}

pub fn commitLinkSymbols(handle: *const anyopaque) void {
    const state = State.borrow(handle);

    state.symbols.commit(&state.builder.symbols);
}

pub fn prepareLinkLiterals(handle: *const anyopaque) Error!bool {
    const state = State.borrow(handle);

    return state.literals.prepare(state.builder, &state.program.expressions, state.borrow_text);
}

pub fn commitLinkLiterals(handle: *const anyopaque) void {
    const state = State.borrow(handle);

    literal_link.Frame.commit(&state.builder.expressions, &state.program.expressions);
}

pub fn commitExpressionLink(handle: *const anyopaque) void {
    const state = State.borrow(handle);

    headers.commit(&state.builder.expressions, state.count);
}
