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
const Schedule = @import("constraints/schedule.zig");
const condition = @import("../condition.zig");
const PortStorage = @import("constraints/ports.zig");
pub const Ports = PortStorage.Slice;

pub fn collect(graph: *Graph, modules: []const Prepared.Module, source_map: SourceMap, arguments: *const Inputs, requests: *Requests) zx.Error!Ports {
    const states = try PortStorage.initialize(graph, modules, source_map);
    const inputs = states.items(.input);
    const outputs = states.items(.output);
    const fixed = states.items(.input_fixed);
    const binding_ends = states.items(.binding_end);
    const task_ends = states.items(.task_end);
    var unused: usize = 0;
    var scope = zx.Arena.init(graph.scratch);

    defer scope.deinit();

    for (modules, 0..) |module, index| {
        scope.reset(std.heap.page_size_min);

        const location = module.source.node.location;
        const input = inputs[index];
        const output = outputs[index];

        var expression = Expression{
            .graph = graph,
            .scope = scope.allocator(),
            .aliases = module.value_imports,
            .input = input,
            .attribute = .{ .name = "", .value = "", .location = location, .value_location = location },
            .span_offset = source_map.base(index),
        };

        var walker = Walker{ .expression = &expression, .module = module, .states = states, .output = output, .arguments = arguments.module(index), .requests = requests };

        if (module.deferred_shortcut) {
            const call = module.calls.get(@import("shorthand.zig").call_index);

            try walker.inferModule(.ModuleShortcut, &fixed[index], &call);
        } else {
            try walker.inferModule(.ModuleBody, &fixed[index], null);
        }

        unused += @intFromBool(!fixed[index]);
        binding_ends[index] = requests.bindings.len;
        task_ends[index] = requests.tasks.len;
    }

    scope.reset(0);

    try @import("input_defaults.zig").apply(graph, inputs, fixed, unused);

    return states;
}

pub const Walker = struct {
    expression: *Expression,
    module: Prepared.Module,
    states: Ports,
    arguments: Inputs.Module,
    output: Graph.Id,
    requests: *Requests,
    returned: bool = false,
    fn inferModule(self: *Walker, comptime form: Schedule.Form, fixed: *bool, shortcut: if (form == .ModuleShortcut) *const Prepared.Call else @TypeOf(null)) zx.Error!void {
        const expression = self.expression;
        const graph = expression.graph;

        inline for (comptime Schedule.steps(form)) |step| {
            switch (step) {
                .Done => {},
                .ForwardPorts => {
                    const target = shortcut.callee.module;
                    const span = graph.nodes.items(.span)[@backingInt(expression.input)];

                    try graph.unify(expression.input, self.states.items(.input)[target], span);
                    try graph.unify(self.output, self.states.items(.output)[target], span);
                },
                .PublishShortcut => {
                    try self.bindResult(names.resolveCall(shortcut.name_source.*), self.output, .call, &expression.bindings);

                    fixed.* = true;
                },
                .InferBody => try @import("constraints/traversal.zig").run(self, self.module.plan.root),
                .DefaultModuleOutput => if (!self.returned) {
                    const span = graph.nodes.items(.span)[@backingInt(self.output)];

                    try graph.unify(self.output, try graph.scalar(.void, span), span);
                },
                .MarkInput => fixed.* = fixed.* or expression.input_used,
                else => unreachable,
            }
        }
    }

    pub fn inferReturn(self: *Walker, attribute: rx.ast.Attribute) zx.Error!void {
        inline for (comptime Schedule.steps(.Return)) |step| {
            switch (step) {
                .Done => {},
                .InferReturn => _ = try inferAttribute(self.expression, self.module.source.path, attribute, self.output),
                .MarkReturned => self.returned = true,
                else => unreachable,
            }
        }
    }

    pub fn enterCase(self: *Walker, parsed: *const frontend.ExpressionInput.Result, subject: Graph.Id, labels: *condition.Cases, cases: []Flow.Case, index: usize) zx.Error!usize {
        if (cases[index].label.kind == .Default) {
            return self.prepareCase(.Default, parsed, subject, labels, cases, index);
        }

        return self.prepareCase(.Case, parsed, subject, labels, cases, index);
    }

    fn prepareCase(self: *Walker, comptime form: Schedule.Form, parsed: *const frontend.ExpressionInput.Result, subject: Graph.Id, labels: *condition.Cases, cases: []Flow.Case, index: usize) zx.Error!usize {
        const expression = self.expression;
        const case = &cases[index];
        var facts: usize = undefined;

        inline for (comptime Schedule.steps(form)) |step| {
            switch (step) {
                .Done, .InferBody, .RestoreFacts, .RestoreBindings => {},
                .InferCaseLabel => {
                    const attribute = case.label.attribute().?;
                    var label = try labels.label(attribute);

                    defer label.deinit();

                    _ = try inferParsedAttribute(expression, &label, attribute, subject);
                    case.truth = condition.boolean(&label);

                    labels.observe(case.truth);
                },
                .InferDefaultLabel => case.truth = try labels.remaining(cases[index + 1 ..]),
                .RefineSubject => {
                    facts = expression.nonnull.items.len;

                    if (case.truth) |present| {
                        try condition.assumeParsed(expression.graph.scratch, parsed, present, expression.conditionScope());
                    }
                },
                else => unreachable,
            }
        }

        return facts;
    }
    pub fn enterParallelTask(self: *Walker, entry: *const Flow.Task) zx.Error!void {
        self.output = try self.expression.graph.add(.unknown, self.taskSpan(entry));
        self.returned = false;
    }

    pub fn finishTask(self: *Walker, entry: *const Flow.Task, parallel_task: bool, bindings: usize, parent_output: Graph.Id, parent_returned: bool, outputs: *Scope.Storage) zx.Error!void {
        if (parallel_task) {
            return self.publishTask(.ParallelTask, entry, bindings, parent_output, parent_returned, outputs);
        }

        return self.publishTask(.Task, entry, bindings, parent_output, parent_returned, outputs);
    }
    fn publishTask(self: *Walker, comptime form: Schedule.Form, entry: *const Flow.Task, bindings: usize, parent_output: Graph.Id, parent_returned: bool, outputs: *Scope.Storage) zx.Error!void {
        const expression = self.expression;
        const graph = expression.graph;
        const span = self.taskSpan(entry);

        var output: ?Graph.Id = if (form == .ParallelTask) self.output else null;

        inline for (comptime Schedule.steps(form)) |step| {
            switch (step) {
                .Done, .EnterTask, .InferBody => {},
                .InferTaskOutput => if (entry.output) |attribute| {
                    output = try inferAttribute(expression, self.module.source.path, attribute, null);
                },
                .DefaultTaskOutput => if (!self.returned) try graph.unify(output.?, try graph.scalar(.void, span), span),
                .RequestTaskOutput => try self.requests.tasks.append(graph.scratch, .{ .id = entry.id.?, .value = output.? }),
                .RestoreReturn => {
                    self.output = parent_output;
                    self.returned = parent_returned;
                },
                .RestoreBindings => expression.bindings.shrinkRetainingCapacity(bindings),
                .PublishTask => if (output) |value| try self.bindResult(names.resolve(entry.node.*), value, .task, outputs),
                else => unreachable,
            }
        }
    }
    fn taskSpan(self: *const Walker, entry: *const Flow.Task) zx.Span {
        const offset = self.expression.span_offset + entry.node.location.offset;

        return .{ .start = offset, .end = offset };
    }
    pub fn inferParsed(self: *Walker, parsed: *const frontend.ExpressionInput.Result, attribute: rx.ast.Attribute, expected: ?Graph.Id) zx.Error!Graph.Id {
        return inferParsedAttribute(self.expression, parsed, attribute, expected);
    }
    pub fn call(self: *Walker, index: usize, outputs: *Scope.Storage) zx.Error!void {
        const invocation = self.module.calls.get(index);

        if (invocation.input != null) return self.inferCall(.CallWithArgument, index, &invocation, outputs);

        return self.inferCall(.CallWithoutArgument, index, &invocation, outputs);
    }
    fn inferCall(self: *Walker, comptime form: Schedule.Form, index: usize, invocation: *const Prepared.Call, outputs: *Scope.Storage) zx.Error!void {
        const expression = self.expression;
        const graph = expression.graph;
        const attribute = invocation.input;
        const offset = if (attribute) |value| value.value_location.offset else invocation.node.location.offset;
        const span = zx.Span{ .start = expression.span_offset + offset, .end = expression.span_offset + offset };
        const count = expression.bindings.len;
        var input: Graph.Id = undefined;
        var output: Graph.Id = undefined;

        inline for (comptime Schedule.steps(form)) |step| {
            switch (step) {
                .Done => {},
                .CallInput => input = switch (invocation.callee) {
                    .module => |module_index| self.states.items(.input)[module_index],
                    .signature => |signature| try graph.known(signature.input_type, span),
                },
                .PublishGetters => {
                    expression.attribute = attribute.?.*;

                    try @import("../store/bindings.zig").infer(graph, &expression.bindings, expression.scope, invocation.getters, span);
                },
                .InferArgument => _ = if (Inputs.input(self.arguments, index)) |parsed|
                    try inferParsedAttribute(expression, parsed, attribute.?.*, input)
                else
                    try inferAttribute(expression, self.module.source.path, attribute.?.*, input),
                .RestoreBindings => expression.bindings.shrinkRetainingCapacity(count),
                .VoidInput => try graph.unify(input, try graph.scalar(.void, span), span),
                .CallOutput => output = switch (invocation.callee) {
                    .module => |module_index| self.states.items(.output)[module_index],
                    .signature => |signature| try graph.known(signature.output_type, span),
                },
                .PublishCall => try self.bindResult(names.resolveCall(invocation.name_source.*), output, .call, outputs),
                else => unreachable,
            }
        }
    }

    fn bindResult(self: *Walker, result: names.Result, output: Graph.Id, kind: enum { call, task }, outputs: *Scope.Storage) zx.Error!void {
        const expression = self.expression;
        const graph = expression.graph;
        expression.attribute = result.attribute;
        const span = expression.sourceSpan(.{ .start = 0, .end = result.attribute.value.len });
        var binding: Scope.Binding = undefined;

        inline for (comptime Schedule.steps(.ResultBinding)) |step| {
            switch (step) {
                .Done => {},
                .BindResultName => {
                    const name = switch (try names.bind(graph.types.allocator, result.name, kind == .task)) {
                        .name => |name| name,
                        .invalid => return graph.reporter.fail(.name, span, "result name must be one identifier; Call targets must have a valid filename"),
                        .reserved => return graph.reporter.fail(.name, span, "Call target name task is reserved for Task results"),
                    };

                    binding = .{ .name = name, .value = output, .span = span };
                },
                .RequestBindingType => try self.requests.bindings.append(graph.types.allocator, .{ .name = binding.name, .value = output }),
                .CheckBindingValue => if (@import("../inference/bindings.zig").isVoid(graph, output)) return,
                .ValidateBindingPath => try Scope.check(graph, expression.bindings.slice(), expression.bindings.len, binding, "flow result paths must not overlap; each visible Call target name must be unique"),
                .PublishBinding => try outputs.append(expression.scope, binding),
                else => unreachable,
            }
        }
    }
};

fn inferAttribute(expression: *Expression, owner: []const u8, attribute: rx.ast.Attribute, expected: ?Graph.Id) zx.Error!Graph.Id {
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
