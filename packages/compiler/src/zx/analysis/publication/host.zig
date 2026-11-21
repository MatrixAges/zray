const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;

const Body = struct {
    symbols: ir.SymbolTable,
    expressions: ir.ExpressionTable,
    stores: ir.StoreTable,
    control: ir.ControlBody,
};

pub fn body(allocator: std.mem.Allocator, source: anytype) std.mem.Allocator.Error!Body {
    const entry = @import("generated_analysis_publish_body");
    const result = columns.invoke(entry.executeValue, allocator, source) catch |err| return failure(err);

    return bodyView(result);
}

pub fn bodyView(result: anytype) Body {
    return .{
        .symbols = columns.columns(ir.SymbolTable, result.symbols.*),
        .expressions = columns.columns(ir.ExpressionTable, result.expressions.*),
        .stores = columns.columns(ir.StoreTable, result.stores.*),
        .control = .{
            .control = columns.pointer(*const ir.ControlTable, result.control),
            .root = if (result.root) |id| @fromBackingInt(id) else null,
        },
    };
}

pub fn values(allocator: std.mem.Allocator, source: anytype) std.mem.Allocator.Error!struct {
    symbols: ir.SymbolTable,
    expressions: ir.ExpressionTable,
} {
    const entry = @import("generated_analysis_publish_values");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .symbols = columns.pointer(@FieldType(Input, "symbols"), source.symbols),
        .expressions = columns.pointer(@FieldType(Input, "expressions"), source.expressions),
    };

    const result = columns.invoke(entry.executeValue, allocator, &input) catch |err| return failure(err);

    return .{
        .symbols = columns.columns(ir.SymbolTable, result.symbols.*),
        .expressions = columns.columns(ir.ExpressionTable, result.expressions.*),
    };
}

pub fn contracts(allocator: std.mem.Allocator, source: anytype) std.mem.Allocator.Error!ir.ContractTable {
    if (source.kinds.len == 0) return .{};

    const entry = @import("generated_analysis_publish_contracts");
    const result = columns.invoke(entry.executeValue, allocator, source) catch |err| return failure(err);

    return columns.columns(ir.ContractTable, result);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
