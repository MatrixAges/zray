const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("terms.zig");
const Expressions = @import("expressions.zig");
const Conditions = @import("conditions.zig");

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
