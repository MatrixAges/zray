const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("terms.zig");
const Expressions = @import("expressions.zig");
const Conditions = @import("conditions.zig");

pub fn evaluate(self: *Expressions, expression: ir.ExpressionRow) zx.Error!terms.Evaluation {
    const invocation = expression.value.call;
    const function = self.program.functions.at(@backingInt(invocation.function));

    if (function.stores.count() != 0) return self.reporter.fail(.unsupported, expression.span, "verification does not model Store calls");
    if (function.external != null) return self.reporter.fail(.unsupported, expression.span, "verification requires a ZX body for each executed call; external semantics are not modeled");

    if (std.mem.indexOfScalar(u32, function.expressions.call_functions, @backingInt(invocation.function)) != null)
        return self.reporter.fail(.unsupported, expression.span, "symbolic execution does not support recursive functions");

    if (self.call_depth >= 128) return self.reporter.fail(.unsupported, expression.span, "verification call depth exceeds 128");

    const argument = try self.evaluate(invocation.argument);
    const cached = try self.graph.calls.lookup(self.allocator, @backingInt(invocation.function), argument.value);

    const callee = switch (cached) {
        .hit => |result| result,
        .miss => |key| blk: {
            const result = try execute(self, function, argument.value);

            try self.graph.calls.publish(self.allocator, key, result);

            break :blk result;
        },
    };

    return .{ .value = callee.value, .safe = try terms.connect(self.allocator, .And, argument.safe, callee.safe) };
}

pub fn execute(self: *Expressions, function: ir.Function, input: terms.Value) zx.Error!terms.Evaluation {
    var program = self.program;

    program.input_type = function.input_type;
    program.output_type = function.output_type;
    program.symbols = function.symbols;
    program.expressions = function.expressions;
    program.body = function.body;
    program.contracts = function.contracts;
    program.stores = .{};
    program.file_name = function.file_name;

    var conditions = Conditions{
        .allocator = self.allocator,
        .scratch = self.scratch,
        .program = program,
        .reporter = self.reporter,
        .input = input,
        .graph = self.graph,
        .call_depth = self.call_depth + 1,
    };

    return conditions.call();
}
