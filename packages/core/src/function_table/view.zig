const ir = @import("../ir.zig");
const Self = @This();

signature: ir.Signature,
store_mode: ir.StoreMode,
body: ir.ControlBody,
symbols: *const ir.SymbolTable,
expressions: *const ir.ExpressionTable,
contracts: *const ir.ContractTable,
stores: *const ir.StoreTable,
pub fn at(table: *const ir.FunctionTable, index: usize) Self {
    return .{
        .signature = ir.SignatureTable.read(table, index),
        .store_mode = table.store_modes[index],
        .body = table.controlAt(index),
        .symbols = table.symbols[index],
        .expressions = table.expressions[index],
        .contracts = table.contracts[index],
        .stores = table.stores[index],
    };
}

pub fn borrow(source: anytype) Self {
    return .{
        .signature = .{
            .file_name = source.file_name,
            .input_type = source.input_type,
            .output_type = source.output_type,
            .output_ownership = source.output_ownership,
            .external = if (@hasField(@TypeOf(source.*), "external")) source.external else null,
        },
        .store_mode = source.store_mode,
        .body = source.body,
        .symbols = &source.symbols,
        .expressions = &source.expressions,
        .contracts = &source.contracts,
        .stores = &source.stores,
    };
}
