const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Graph = @import("../inference/types.zig");
const Expression = @import("../inference/expression.zig");
const Scope = @import("../inference/scope.zig");
const Flow = @import("flow.zig");
const SourceMap = @import("../source_map.zig");
const Prepared = @import("prepare.zig");
const Inputs = @import("call_inputs.zig");
const names = @import("../result_name.zig");
const Requests = @import("signatures/requests.zig");
const Call = @import("constraints/call.zig");
const PortStorage = @import("constraints/ports.zig");
const Collection = @import("constraints/collection.zig");
pub const Ports = PortStorage.Slice;

pub fn collectSeed(graph: *Graph, modules: []const Prepared.Module, source_map: SourceMap, arguments: *const Inputs, requests: *Requests) zx.Error!Ports {
    const states = try PortStorage.initializeSeed(graph, modules, source_map);

    var collection: Collection = .{
        .graph = graph,
        .modules = modules,
        .source_map = source_map,
        .states = states,
        .arguments = arguments,
        .requests = requests,
        .scope = zx.Arena.init(graph.scratch),
    };

    defer collection.scope.deinit();

    try collection.seed();

    return states;
}

pub const Walker = struct {
    expression: *Expression,
    module: *const Prepared.Module,
    states: Ports,
    arguments: Inputs.Module,
    output: Graph.Id,
    requests: *Requests,
    binding_first: usize,
    task_first: usize,
    returned: bool = false,
    pub fn forwardShortcut(self: *Walker) zx.Error!void {
        const expression = self.expression;
        const graph = expression.graph;
        const shortcut = self.module.calls.get(@import("shorthand.zig").call_index);
        const target = shortcut.callee.module;
        const span = graph.nodes.items(.span)[@backingInt(expression.input)];

        try graph.unify(expression.input, self.states.items(.input)[target], span);
        try graph.unify(self.output, self.states.items(.output)[target], span);
        try self.bindResult(names.resolveCall(shortcut.name_source.*), self.output, .call, &expression.bindings);

        expression.input_used = true;
    }
    pub fn inferBody(self: *Walker) zx.Error!void {
        try @import("constraints/traversal.zig").run(self, self.module.plan.root);
    }

    pub fn inferReturn(self: *Walker, attribute: rx.ast.Attribute) zx.Error!void {
        _ = try inferAttribute(self.expression, self.module.source.path, attribute, self.output);
    }
    pub fn enterParallelTask(self: *Walker, entry: *const Flow.Task) zx.Error!void {
        self.output = try self.expression.graph.add(.unknown, self.taskSpan(entry));
        self.returned = false;
    }

    pub fn finishTask(self: *Walker, entry: *const Flow.Task, parallel_task: bool, bindings: usize, parent_output: Graph.Id, parent_returned: bool, outputs: *Scope.Storage) zx.Error!void {
        const output = if (parallel_task) try self.parallelTaskOutput(entry) else try self.taskOutput(entry);

        if (parallel_task) {
            try self.requestTaskOutput(entry);

            self.output = parent_output;
            self.returned = parent_returned;
        }

        self.expression.bindings.shrinkRetainingCapacity(bindings);

        if (output) |value| try self.bindTaskOutput(entry, value, outputs);
    }

    pub fn taskOutput(self: *Walker, entry: *const Flow.Task) zx.Error!?Graph.Id {
        const attribute = entry.output orelse return null;

        return try inferAttribute(self.expression, self.module.source.path, attribute.*, null);
    }
    pub fn parallelTaskOutput(self: *Walker, entry: *const Flow.Task) zx.Error!Graph.Id {
        if (!self.returned) {
            const graph = self.expression.graph;
            const span = self.taskSpan(entry);

            try graph.unify(self.output, try graph.scalar(.void, span), span);
        }

        return self.output;
    }
    pub fn requestTaskOutput(self: *Walker, entry: *const Flow.Task) zx.Error!void {
        try self.requests.recordTask(self.expression.graph.types.allocator, self.task_first, entry.id.?, self.requests.bindings.len - self.binding_first);
    }
    pub fn bindTaskOutput(self: *Walker, entry: *const Flow.Task, value: Graph.Id, outputs: *Scope.Storage) zx.Error!void {
        try self.bindResult(names.resolve(entry.node.*), value, .task, outputs);
    }
    fn taskSpan(self: *const Walker, entry: *const Flow.Task) zx.Span {
        const offset = self.expression.span_offset + entry.node.location.offset;

        return .{ .start = offset, .end = offset };
    }
    pub fn inferParsed(self: *Walker, parsed: *const frontend.ExpressionInput.Result, attribute: rx.ast.Attribute, expected: ?Graph.Id) zx.Error!Graph.Id {
        return inferParsedAttribute(self.expression, parsed, attribute, expected);
    }
    pub fn call(self: *Walker, row: usize, outputs: *Scope.Storage) zx.Error!void {
        const count = self.expression.bindings.len;
        var work: Call = undefined;

        try Call.prepare(self, row, &work);

        if (work.invocation.input != null) {
            try work.bindGetters(self);
            try work.argument(self);

            self.expression.bindings.shrinkRetainingCapacity(count);
        } else {
            try work.unit(self);
        }

        try work.publish(self, outputs);
    }
    pub fn bindResult(self: *Walker, result: names.Result, output: Graph.Id, kind: enum { call, task }, outputs: *Scope.Storage) zx.Error!void {
        const expression = self.expression;
        const graph = expression.graph;
        expression.attribute = result.attribute;
        const span = expression.sourceSpan(.{ .start = 0, .end = result.attribute.value.len });

        const name = switch (try names.bind(graph.types.allocator, result.name, kind == .task)) {
            .name => |name| name,
            .invalid => return graph.reporter.fail(.name, span, "result name must be one identifier; Call targets must have a valid filename"),
            .reserved => return graph.reporter.fail(.name, span, "Call target name task is reserved for Task results"),
        };

        const binding: Scope.Binding = .{ .name = name, .value = output, .span = span };

        try self.requests.bindings.append(graph.types.allocator, .{ .name = name, .value = output });
        if (@import("../inference/bindings.zig").isVoid(graph, output)) return;
        try Scope.check(graph, expression.bindings.slice(), expression.bindings.len, binding, "flow result paths must not overlap; each visible Call target name must be unique");
        try outputs.append(expression.scope, binding);
    }
};

pub fn inferAttribute(expression: *Expression, owner: []const u8, attribute: rx.ast.Attribute, expected: ?Graph.Id) zx.Error!Graph.Id {
    var parsed = try @import("../attribute.zig").parseBorrowed(expression.graph.scratch, attribute, owner);

    defer parsed.deinit();

    return inferParsedAttribute(expression, &parsed, attribute, expected);
}

fn inferParsedAttribute(expression: *Expression, parsed: *const frontend.ExpressionInput.Result, attribute: rx.ast.Attribute, expected: ?Graph.Id) zx.Error!Graph.Id {
    expression.attribute = attribute;
    const allocator = expression.graph.allocator;

    if (parsed.diagnostic()) |issue| {
        const message = try allocator.dupe(u8, issue.message);

        return expression.graph.reporter.fail(issue.code, expression.sourceSpan(issue.span), message);
    }

    return switch (parsed.*) {
        .native => |result| expression.infer(result.value.parsed.expression, expected),
        .indexed => |result| if (@import("frontend").ExpressionInput.indexed_enabled) block: {
            var scratch = std.heap.ArenaAllocator.init(expression.graph.scratch);

            defer scratch.deinit();

            const view = try result.view(scratch.allocator());

            break :block try expression.infer(view.expression(result.output.result), expected);
        } else unreachable,
    };
}
