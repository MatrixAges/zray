const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const node = @import("../../node.zig");
const generated = @import("genz_options").generated_analysis;
const entry = @import("generated_scope_advance_binding");
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

const Input = std.meta.Child(entry.Input);
const Selection = std.meta.Child(@FieldType(Input, "selection"));
const SpanColumns = std.meta.Child(std.meta.Child(@FieldType(Input, "spans")));
const ValueColumns = std.meta.Child(std.meta.Child(@FieldType(Input, "values")));
pub const Request = std.meta.Child(entry.Output);
pub const Spans = struct { starts: []u32, counts: []u32 };
pub const Values = struct { values: []?u32, types: []?u32, names: [][]const u8 };

pub fn begin(count: usize) Request {
    return .{ .action = .Begin, .position = count, .symbol = null, .value = 0, .name = &.{}, .type_id = null };
}

pub fn binding(request: Request) Binding {
    const action: Action = switch (request.action) {
        inline .Reuse, .Skip, .Task, .Discard, .Value, .Ordinary, .Iteration => |selected| @field(Action, @tagName(selected)),
        else => unreachable,
    };

    return .{
        .position = @intCast(request.position),
        .symbol = if (request.symbol) |id| @fromBackingInt(id) else null,
        .value = @fromBackingInt(request.value),
        .action = action,
    };
}

pub fn advance(self: *const Lower, scope: ir.ScopeRow, changes: []const ?u32, tables: anytype, previous: *const Request, emitted: node.Block) Request {
    const iteration = @TypeOf(tables) == *const Values;
    const stack = self.stack_symbols.view(std.meta.Child(@FieldType(Selection, "stack")));
    const expressions = &self.program.expressions;

    const selection: Selection = .{
        .symbols = scope.bindings.symbols,
        .values = scope.bindings.values,
        .kinds = zx.columns.slice(@FieldType(Selection, "kinds"), expressions.kinds),
        .types = expressions.types,
        .type_kinds = self.program.types.kinds,
        .used = self.used,
        .stack = &stack,
        .changes = changes,
        .iteration = iteration,
    };

    const spans: SpanColumns = if (iteration) undefined else .{ .starts = @ptrCast(&tables.starts), .counts = @ptrCast(&tables.counts) };

    const values: ValueColumns = if (iteration) .{
        .values = @ptrCast(&tables.values),
        .types = @ptrCast(&tables.types),
        .names = @ptrCast(&tables.names),
    } else undefined;

    const input: Input = .{
        .selection = &selection,
        .previous = previous,
        .value = emitted.start,
        .count = emitted.len,
        .spans = if (iteration) null else &spans,
        .values = if (iteration) &values else null,
        .names = if (iteration) self.names else &.{},
        .symbol_types = if (iteration) self.program.symbols.types else &.{},
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const request = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

    return zx.columns.view(Request, request);
}

pub const Result = struct {
    type_id: ir.TypeId,
    candidate: ?Candidate,
    count: usize,
    consumed_count: usize,
};

const Candidate = struct { symbol: ir.SymbolId, value: ir.ExprId };

pub fn result(self: *const Lower, scope: ir.ScopeRow) Result {
    if (!generated) {
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
        .consumed_count = @intCast(output.consumed_count),
    };
}
