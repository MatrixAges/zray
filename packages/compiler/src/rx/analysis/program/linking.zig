const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("builder.zig");
pub const missing = std.math.maxInt(u32);

pub const Plan = struct {
    returned: ir.ExprId,
    rows: []const u32,
    bindings: []const u32,
    count: usize,
};

pub fn validate(builder: *const Builder, program: *const ir.Program) Builder.Error!ir.Block {
    const block = program.body.block();

    if (block.len == 0 or program.symbols.count() < block.len) return error.InvalidModule;
    if (program.functions.count() != 0 or program.stores.count() != 0) return error.InvalidModule;
    if (program.expressions.count() > missing - builder.expressions.count()) return error.OutOfMemory;

    return block;
}
