const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
pub const Action = enum { Reuse, Skip, Task, Discard, Value, Ordinary, Iteration };

pub const Binding = struct {
    position: usize,
    symbol: ?ir.SymbolId,
    value: ir.ExprId,
    action: Action,
};

pub fn seedNext(self: *const Lower, scope: ir.ScopeRow, remaining: usize) Binding {
    const position = remaining - 1;
    const item = scope.bindings.at(position);
    const route = @import("../binding.zig").before(self, item.value, item.symbol, true);

    return .{
        .position = position,
        .symbol = item.symbol,
        .value = item.value,
        .action = switch (route) {
            .Skip => .Skip,
            .Task => .Task,
            .Ordinary => if (item.symbol) |symbol|
                if (self.stack_symbols.contains(symbol)) .Value else .Ordinary
            else
                .Discard,
        },
    };
}

pub const Result = struct {
    type_id: ir.TypeId,
    candidate: ?Candidate,
    count: usize,
    consumed_count: usize,
};

const Candidate = struct { symbol: ir.SymbolId, value: ir.ExprId };

pub fn result(self: *const Lower, scope: ir.ScopeRow) Result {
    const count = scope.bindings.len;
    const tail = if (count == 0) null else scope.bindings.at(count - 1);
    const candidate: ?Candidate = if (tail) |last| if (last.symbol) |symbol| .{ .symbol = symbol, .value = last.value } else null else null;

    return .{
        .type_id = self.program.expression(scope.result).type_id,
        .candidate = candidate,
        .count = count,
        .consumed_count = count -| 1,
    };
}
