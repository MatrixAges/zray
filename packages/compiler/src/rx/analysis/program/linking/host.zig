const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Mapping = @import("../mapping.zig");
const symbol_link = @import("symbols.zig");
const literal_link = @import("literals/host.zig");
const headers = @import("headers.zig");
const operands = @import("operands/host.zig");
const abi = @import("abi.zig");
const Plan = std.meta.Child(@typeInfo(@FieldType(abi.Request, "plan")).optional.child);
const Error = Builder.Error;

pub fn run(builder: *Builder, program: *const ir.Program, block: ir.Block, borrow_text: bool, allocator: std.mem.Allocator) Error!ir.ExprId {
    const target = builder.symbols.view();
    const table = &program.expressions;
    const storage = &builder.expressions;
    const base = storage.count();
    const control = block.control;
    const Body = std.meta.Child(@FieldType(Plan, "body"));
    const Expressions = std.meta.Child(@FieldType(Plan, "expressions"));

    var input: abi.Request = .{
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
            .base = base,
        },
        .symbols = null,
        .literals = null,
        .payload = null,
        .operands = null,
        .first = null,
    };

    const initial = (try execute(allocator, &input)).initial orelse return error.InvalidModule;
    const count: usize = @intCast(initial.count);

    const mapping: Mapping = .{
        .bindings = initial.bindings,
        .locals_base = target.count(),
        .symbol_count = program.symbols.count(),
        .expressions = initial.rows,
    };

    try storage.reserveHeaders(builder.allocator, count);

    input.plan = null;

    var symbols: symbol_link.Frame = .{};
    var literals: literal_link.Frame = .{};

    if (try symbols.prepare(builder, &program.symbols, initial.bindings.len + 1, borrow_text)) input.symbols = &symbols.input;
    if (try literals.prepare(builder, table, borrow_text)) input.literals = &literals.input;

    if (input.symbols != null or input.literals != null) {
        const publication = (try execute(allocator, &input)).publication.?;

        if (publication.symbols) |rows| try symbol_link.publish(builder, rows);
        if (publication.literals) |rows| try literal_link.publish(builder, rows);
    }

    const target_payloads = storage.payloads.unusedCapacitySlice()[0..count];

    const payload: abi.Payload = .{
        .kinds = zx.columns.slice(@FieldType(abi.Payload, "kinds"), table.kinds),
        .payloads = table.payloads,
        .rows = initial.rows,
        .literals = &literals.bases,
        .base = base,
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var bytes: [4096]u8 = undefined;
    var operand_rows: operands.Frame = .{};

    operand_rows.initialize(storage, table);
    operand_rows.bind(&mapping);

    input.symbols = null;
    input.literals = null;
    input.payload = &payload;
    input.operands = &operand_rows.input;
    input.first = initial.first;

    while (input.first != null) {
        var scratch = std.heap.BufferFirstAllocator.init(&bytes, arena.allocator());
        const step = (try execute(scratch.allocator(), &input)).step orelse return error.InvalidModule;

        for (step.writes) |write| target_payloads[write.index] = write.value;
        if (step.patch) |patch| try operands.Frame.commit(builder, patch);
        if (step.operand) |operand| target_payloads[operand.index] = operand.value;

        input.first = step.next;
        _ = arena.reset(.retain_capacity);
    }

    headers.commit(storage, table, initial.ranges, count);

    return @fromBackingInt(initial.returned);
}

fn execute(allocator: std.mem.Allocator, input: *const abi.Request) Error!abi.Output {
    return zx.columns.invoke(abi.entry.executeValue, allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow, error.IntegerOverflow => if (input.plan != null) error.OutOfMemory else error.InvalidModule,
        error.IndexOutOfBounds, error.InvalidModule => error.InvalidModule,
        else => unreachable,
    };
}
