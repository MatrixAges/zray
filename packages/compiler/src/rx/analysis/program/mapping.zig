const ir = @import("zx").ir;
const Error = @import("builder.zig").Error;
const missing = @import("linking.zig").missing;
const Self = @This();

bindings: []const u32,
locals_base: usize,
symbol_count: usize,
expressions: []const u32,

available: usize = 0,
pub fn seedId(self: *const Self, value: ir.ExprId) Error!ir.ExprId {
    const index = @backingInt(value);

    if (index >= self.available) return error.InvalidModule;

    const target = self.expressions[index];

    return if (target == missing) error.InvalidModule else @fromBackingInt(target);
}

pub fn seedSymbol(self: *const Self, value: ir.SymbolId) Error!ir.SymbolId {
    const index = @backingInt(value);

    if (index == 0 or index >= self.symbol_count) return error.InvalidModule;

    const offset = index - 1;

    if (offset >= self.bindings.len) return @fromBackingInt(@intCast(self.locals_base + (offset - self.bindings.len)));

    const target = self.bindings[offset];

    return if (target == missing) error.InvalidModule else @fromBackingInt(target);
}
