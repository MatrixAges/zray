const std = @import("std");
const ir = @import("zx").ir;
const forward = @import("forward_entry/host.zig").write;
const generated = @import("parser_options").generated_parser;

pub fn value(program: ir.Program) ir.Function {
    return .{
        .stores = program.stores,
        .store_mode = program.store_mode,
        .output_ownership = program.output_ownership,
        .file_name = program.file_name,
        .input_type = program.input_type,
        .output_type = program.output_type,
        .symbols = program.symbols,
        .expressions = program.expressions,
        .body = program.body,
        .contracts = program.contracts,
    };
}

pub fn calls(expressions: ir.ExpressionTable, id: ir.FunctionId) bool {
    if (comptime generated) {
        const rule = @import("generated_recursive_call");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return (rule.executeValue(empty.allocator(), .{
            .calls = expressions.call_functions,
            .candidate = @backingInt(id),
        }) catch unreachable) != null;
    }

    return std.mem.indexOfScalar(u32, expressions.call_functions, @backingInt(id)) != null;
}

pub fn own(program: ir.Program) ?ir.FunctionId {
    if (program.type_only or program.functions.count() == 0) return null;

    const index = program.functions.count() - 1;
    const id: ir.FunctionId = @fromBackingInt(@intCast(index));

    return if (calls(program.expressions, id) and std.meta.eql(value(program), program.functions.at(index))) id else null;
}

pub fn entry(allocator: std.mem.Allocator, program: *ir.Program, id: ir.FunctionId) std.mem.Allocator.Error!void {
    try forward(allocator, program, .{ .id = id, .parameter = program.symbols.at(0), .unit = false });

    program.contracts = .{};
}

pub fn externalEntry(allocator: std.mem.Allocator, program: *ir.Program, id: ir.FunctionId) std.mem.Allocator.Error!void {
    const parameter: ir.Symbol = .{ .name = "$in", .type_id = program.input_type, .span = .{ .start = 0, .end = 0 } };

    try forward(allocator, program, .{
        .id = id,
        .parameter = parameter,
        .unit = false,
    });

    program.contracts = .{};
}

pub fn complete(allocator: std.mem.Allocator, program: *ir.Program, functions: ir.FunctionTable, declared: bool) std.mem.Allocator.Error!?ir.FunctionId {
    program.functions = functions;

    if (!declared or program.type_only) return null;

    const id: ir.FunctionId = @fromBackingInt(@intCast(functions.count()));

    if (!calls(program.expressions, id)) return null;

    try appendEntry(allocator, program);

    return id;
}

pub fn appendEntry(allocator: std.mem.Allocator, program: *ir.Program) std.mem.Allocator.Error!void {
    var storage: ir.FunctionStorage = .{};

    try storage.append(allocator, value(program.*));

    program.functions = try @import("link/function_table.zig").join(allocator, program.functions, try storage.finish(allocator));
}
