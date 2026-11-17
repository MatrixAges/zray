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
    return ownTail(program, program.functions, 0);
}

pub fn ownTail(program: ir.Program, tail: ir.FunctionTable, first: usize) ?ir.FunctionId {
    if (comptime generated) {
        const rule = @import("generated_source_owned_entry");

        const input: std.meta.Child(rule.Input) = .{
            .calls = program.expressions.call_functions,
            .count = tail.count(),
            .first = first,
            .type_only = program.type_only,
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});
        const candidate = @import("zx").columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

        if (candidate == null) return null;

        return if (std.meta.eql(value(program), tail.at(tail.count() - 1))) @fromBackingInt(candidate.?) else null;
    }

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
