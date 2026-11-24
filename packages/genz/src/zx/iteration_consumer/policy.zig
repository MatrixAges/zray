const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub fn projection(program: *const ir.Program, result: ir.ExprId, symbol: ir.SymbolId) bool {
    const query = @import("generated_consumer_projection");
    const Arguments = std.meta.Child(query.Input);

    const input: Arguments = .{
        .table = zx.columns.pointer(@FieldType(Arguments, "table"), &program.expressions),
        .result = @backingInt(result),
        .symbol = @backingInt(symbol),
    };

    return invoke(query, &input);
}

pub fn independent(program: *const ir.Program, id: ir.ExprId, symbol: ir.SymbolId) bool {
    const query = @import("generated_consumer_independent");
    const Arguments = std.meta.Child(query.Input);

    const input: Arguments = .{
        .table = zx.columns.pointer(@FieldType(Arguments, "table"), &program.expressions),
        .id = @backingInt(id),
        .symbol = @backingInt(symbol),
    };

    return invoke(query, &input);
}

fn invoke(comptime query: type, input: anytype) bool {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(query.executeValue, fixed.allocator(), input) catch @panic("invalid iteration consumer projection");
}
