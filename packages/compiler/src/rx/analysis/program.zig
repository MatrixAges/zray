const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Module = @import("module.zig");
const Builder = @import("program/builder.zig");
const Flow = @import("program/flow.zig");
const Plan = @import("program/control/plan.zig");
const Writer = @import("program/control/writer.zig");
const Statements = @import("program/statements.zig");
const Capture = @import("program/capture.zig");

pub const Options = struct {
    owner: []const u8,
    types: ir.TypeTable,
    input_type: ir.TypeId,
    output_type: ir.TypeId,
    captures: ?Capture.Parameters = null,
    calls: []const Module.Call,
    native_modules: ir.NativeModuleTable,
    shared_functions: ir.FunctionTable,
    store_initializers: []const @import("frontend").project.compiled.StoreInitializer = &.{},
    flow: *const Flow,
    retain_metadata: bool = false,
};

pub const Result = struct { program: ir.Program, store_initializers: []const @import("frontend").project.compiled.StoreInitializer };

pub fn lower(allocator: std.mem.Allocator, contract: Options) Builder.Error!Result {
    var builder = Builder{ .allocator = allocator, .types = contract.types, .native_modules = contract.native_modules, .base_functions = contract.shared_functions };

    defer builder.linking_scratch.deinit();
    defer builder.store_initializers.deinit();

    for (contract.store_initializers) |initial| try builder.initializer(initial);

    builder.store_initializers.checked_prefix = contract.store_initializers;

    const body = try lowerBody(&builder, contract);

    return .{ .store_initializers = builder.store_initializers.rows.items, .program = .{
        .file_name = try allocator.dupe(u8, contract.owner),
        .types = contract.types,
        .symbols = builder.symbols.view(),
        .expressions = builder.expressions.view(),
        .input_type = contract.input_type,
        .output_type = contract.output_type,
        .body = body,
        .functions = try @import("frontend").project.artifact.function_table.join(allocator, builder.base_functions, builder.functions.view()),
        .stores = builder.stores.view(),
        .store_mode = .orchestration,
        .native_modules = contract.native_modules,
    } };
}

fn lowerBody(builder: *Builder, contract: Options) Builder.Error!ir.ControlBody {
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = scratch.allocator();
    var writer = try Writer.init(builder.allocator, contract.flow.block_count);

    errdefer writer.columns.deinit(builder.allocator);

    const capture_count = if (contract.captures) |captures| captures.types.len else 0;

    const blocks = Plan.Blocks{
        .firsts = writer.columns.block_first.items,
        .counts = writer.columns.block_count.items,
    };

    const plan = try Plan.make(temporary, contract.flow, blocks, capture_count, @backingInt(contract.output_type) == @backingInt(ir.Scalar.void));
    const unit = plan.root();
    const row = plan.rows[unit];
    var cursor = Writer.Cursor.init(row.first);

    try writer.reserve(builder.allocator, plan.size);

    const start = zx.Span{ .start = 0, .end = 0 };

    if (contract.captures) |captures| {
        try Capture.bind(builder, &writer, &cursor, contract.input_type, captures, start);
    } else {
        const input = try builder.symbol("$in", contract.input_type, start);

        if (@backingInt(contract.input_type) != @backingInt(ir.Scalar.void)) try builder.bindings.append(builder.allocator, input);
    }

    const statements = Statements{ .builder = builder, .flow = contract.flow, .plan = plan, .writer = &writer, .calls = contract.calls, .retain_metadata = contract.retain_metadata };

    try statements.lower(unit, &cursor);
    if (plan.implicit_return) writer.result(&cursor, null);

    const root = try writer.finishBlock(&cursor, row.tag, &plan.size);

    return writer.columns.finish(builder.allocator, root);
}
