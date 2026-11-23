const zx = @import("zx");
const Graph = @import("../../inference/types.zig");
const Scope = @import("../../inference/scope.zig");
const Prepared = @import("../prepare.zig");
const Inputs = @import("../call_inputs.zig");
const names = @import("../../result_name.zig");
const constraints = @import("../constraints.zig");
const Walker = constraints.Walker;
const Self = @This();

invocation: Prepared.Call,
row: usize,
span: zx.Span,
input: Graph.Id,
pub fn prepare(walker: *Walker, row: usize, work: *Self) zx.Error!void {
    const expression = walker.expression;
    const graph = expression.graph;
    const invocation = walker.module.calls.get(row);
    const offset = if (invocation.input) |value| value.value_location.offset else invocation.node.location.offset;
    const span = zx.Span{ .start = expression.span_offset + offset, .end = expression.span_offset + offset };

    const input = switch (invocation.callee) {
        .module => |module| walker.states.items(.input)[module],
        .signature => |signature| try graph.known(signature.input_type, span),
    };

    work.* = .{ .invocation = invocation, .row = row, .span = span, .input = input };
}

pub fn bindGetters(self: *const Self, walker: *Walker) zx.Error!void {
    const attribute = self.invocation.input orelse return;
    const expression = walker.expression;
    expression.attribute = attribute.*;

    try @import("../../store/bindings.zig").infer(expression.graph, &expression.bindings, expression.scope, self.invocation.getters, self.span);
}

pub fn argument(self: *const Self, walker: *Walker) zx.Error!void {
    const attribute = self.invocation.input.?.*;

    if (Inputs.input(walker.arguments, self.row)) |parsed| {
        _ = try walker.inferParsed(parsed, attribute, self.input);
    } else {
        _ = try constraints.inferAttribute(walker.expression, walker.module.source.path, attribute, self.input);
    }
}

pub fn unit(self: *const Self, walker: *Walker) zx.Error!void {
    const graph = walker.expression.graph;

    try graph.unify(self.input, try graph.scalar(.void, self.span), self.span);
}

pub fn publish(self: *const Self, walker: *Walker, outputs: *Scope.Storage) zx.Error!void {
    const graph = walker.expression.graph;

    const output = switch (self.invocation.callee) {
        .module => |module| walker.states.items(.output)[module],
        .signature => |signature| try graph.known(signature.output_type, self.span),
    };

    try walker.bindResult(names.resolveCall(self.invocation.name_source.*), output, .call, outputs);
}
