const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;
const entry = @import("generated_scope_next_binding");
pub const Action = enum { Reuse, Skip, Task, Discard, Value, Ordinary, Iteration };

pub const Binding = struct {
    position: usize,
    symbol: ?ir.SymbolId,
    value: ir.ExprId,
    action: Action,
};

pub fn next(self: *const Lower, scope: ir.ScopeRow, remaining: usize, changes: []const ?u32, iteration: bool) Binding {
    if (!generated) {
        const position = remaining - 1;
        const binding = scope.bindings.at(position);
        const route = @import("../binding.zig").before(self, binding.value, binding.symbol, true);

        return .{
            .position = position,
            .symbol = binding.symbol,
            .value = binding.value,
            .action = switch (route) {
                .Skip => .Skip,
                .Task => .Task,
                .Ordinary => if (binding.symbol) |symbol|
                    if (self.stack_symbols.contains(symbol)) .Value else .Ordinary
                else
                    .Discard,
            },
        };
    }

    const Input = std.meta.Child(entry.Input);
    const stack = self.stack_symbols.view(std.meta.Child(@FieldType(Input, "stack")));
    const expressions = &self.program.expressions;

    const input: Input = .{
        .symbols = scope.bindings.symbols,
        .values = scope.bindings.values,
        .kinds = zx.columns.slice(@FieldType(Input, "kinds"), expressions.kinds),
        .types = expressions.types,
        .type_kinds = self.program.types.kinds,
        .used = self.used,
        .stack = &stack,
        .changes = changes,
        .iteration = iteration,
        .remaining = remaining,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const output = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

    return .{
        .position = @intCast(output.position),
        .symbol = if (output.symbol) |symbol| @fromBackingInt(symbol) else null,
        .value = @fromBackingInt(output.value),
        .action = zx.columns.view(Action, output.action),
    };
}

pub const Result = struct {
    type_id: ir.TypeId,
    candidate: ?Candidate,
    count: usize,
};

const Candidate = struct { symbol: ir.SymbolId, value: ir.ExprId };

pub fn result(self: *const Lower, scope: ir.ScopeRow) Result {
    if (!generated) {
        const count = scope.bindings.len;
        const binding = if (count == 0) null else scope.bindings.at(count - 1);
        const candidate: ?Candidate = if (binding) |last| if (last.symbol) |symbol| .{ .symbol = symbol, .value = last.value } else null else null;

        return .{
            .type_id = self.program.expression(scope.result).type_id,
            .candidate = candidate,
            .count = count,
        };
    }

    const resolve = @import("generated_scope_result");

    const input: std.meta.Child(resolve.Input) = .{
        .symbols = scope.bindings.symbols,
        .values = scope.bindings.values,
        .types = self.program.expressions.types,
        .result = @backingInt(scope.result),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const output = zx.columns.invoke(resolve.executeValue, fixed.allocator(), &input) catch unreachable;

    return .{
        .type_id = @fromBackingInt(output.type_id),
        .candidate = if (output.candidate) |candidate| .{
            .symbol = @fromBackingInt(candidate.symbol),
            .value = @fromBackingInt(candidate.value),
        } else null,
        .count = @intCast(output.count),
    };
}
