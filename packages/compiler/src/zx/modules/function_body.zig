const std = @import("std");
const ir = @import("zx").ir;
const forward = @import("forward_entry/host.zig").write;

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
    return std.mem.indexOfScalar(u32, expressions.call_functions, @backingInt(id)) != null;
}

pub fn ownTail(program: ir.Program, tail: ir.FunctionTable, first: usize) ?ir.FunctionId {
    if (program.type_only or tail.count() == 0) return null;

    const row = tail.count() - 1;
    const id: ir.FunctionId = @fromBackingInt(@intCast(first + row));

    return if (calls(program.expressions, id) and std.meta.eql(value(program), tail.at(row))) id else null;
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

pub fn completeSeed(allocator: std.mem.Allocator, program: *ir.Program, functions: ir.FunctionTable, declared: bool) std.mem.Allocator.Error!?ir.FunctionId {
    program.functions = functions;

    if (!declared or program.type_only) return null;

    const id: ir.FunctionId = @fromBackingInt(@intCast(functions.count()));

    if (!calls(program.expressions, id)) return null;

    program.functions = try @import("link/function_table.zig").join(allocator, functions, try single(allocator, program.*));

    return id;
}

pub fn single(allocator: std.mem.Allocator, program: ir.Program) std.mem.Allocator.Error!ir.FunctionTable {
    var storage: ir.FunctionStorage = .{};

    try storage.append(allocator, value(program));

    return storage.finish(allocator);
}
