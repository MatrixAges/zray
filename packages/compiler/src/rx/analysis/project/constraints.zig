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

const Walker = struct {
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
                .InferBody => try self.steps(self.module.plan.root),
                .DefaultModuleOutput => if (!self.returned) {
                    const span = graph.nodes.items(.span)[@backingInt(self.output)];

                    try graph.unify(self.output, try graph.scalar(.void, span), span);
                },
                .MarkInput => fixed.* = fixed.* or expression.input_used,
                else => unreachable,
            }
        }
    }
    fn steps(self: *Walker, sequence: Flow.Unit) zx.Error!void {
        const expression = self.expression;
        const plan = &self.module.plan;
        var cursor = sequence;

        while (plan.next(&cursor)) |run| switch (run.kind) {
            .Call => for (run.items) |index| try self.call(index, &expression.bindings),
            .Parallel => try self.parallel(plan.groups[run.items[0]]),
            .Result => try self.inferReturn(plan.results[run.items[0]]),
            .Task => try self.task(.Task, &plan.tasks[run.items[0]], &expression.bindings),
            .Selection => try self.selection(run.items[0]),
            .ParallelTask => unreachable,
        };
    }
    fn parallel(self: *Walker, branches: Flow.Unit) zx.Error!void {
        const expression = self.expression;
        const plan = &self.module.plan;
        var outputs: Scope.Storage = .empty;

        defer outputs.deinit(expression.scope);

        inline for (comptime Schedule.steps(.Parallel)) |step| {
            switch (step) {
                .Done => {},
                .InferBranches => for (plan.indices(branches), plan.kinds[branches.first..][0..branches.count]) |index, kind| {
                    switch (kind) {
                        .Call => try self.call(index, &outputs),
                        .ParallelTask => try self.task(.ParallelTask, &plan.tasks[index], &outputs),
                        else => unreachable,
                    }
                },
                .PublishParallel => try Scope.publishParallel(expression.graph, &expression.bindings, expression.scope, outputs.slice()),
                else => unreachable,
            }
        }
    }

    fn inferReturn(self: *Walker, attribute: rx.ast.Attribute) zx.Error!void {
        inline for (comptime Schedule.steps(.Return)) |step| {
            switch (step) {
                .Done => {},
                .InferReturn => _ = try inferAttribute(self.expression, self.module.source.path, attribute, self.output),
                .MarkReturned => self.returned = true,
                else => unreachable,
            }
        }
    }

    const Cases = struct {
        parsed: *const frontend.ExpressionInput.Result,
        subject: Graph.Id,
        labels: *condition.Cases,
        cases: []Flow.Case,
        bindings: usize,
    };
    fn selection(self: *Walker, index: usize) zx.Error!void {
        const entry = &self.module.plan.selections[index];
        const expression = self.expression;
        const owner = self.module.source.path;
        const allocator = expression.scope;
        var parsed: ?frontend.ExpressionInput.Result = null;
        var subject: Graph.Id = undefined;
        var labels: condition.Cases = .{ .allocator = allocator, .owner = owner };

        defer if (parsed) |*result| result.deinit();
        defer labels.deinit();

        inline for (comptime Schedule.steps(.Selection)) |step| {
            switch (step) {
                .Done => {},
                .ParseSubject => parsed = try @import("../attribute.zig").parseBorrowed(allocator, entry.subject.*, owner),
                .InferSubject => subject = try inferParsedAttribute(expression, &parsed.?, entry.subject.*, null),
                .InferCases => {
                    const context: Cases = .{ .parsed = &parsed.?, .subject = subject, .labels = &labels, .cases = entry.cases, .bindings = expression.bindings.len };

                    for (entry.cases, 0..) |*case, row| {
                        if (case.label.kind != .Default) {
                            try self.inferCase(.Case, &context, row);
                        } else try self.inferCase(.Default, &context, row);
                    }
                },
                else => unreachable,
            }
        }
    }
    fn inferCase(self: *Walker, comptime form: Schedule.Form, context: *const Cases, index: usize) zx.Error!void {
        const expression = self.expression;
        const case = &context.cases[index];
        var facts: usize = undefined;

        inline for (comptime Schedule.steps(form)) |step| {
            switch (step) {
                .Done => {},
                .InferCaseLabel => {
                    const attribute = case.label.attribute().?;
                    var label = try context.labels.label(attribute);

                    defer label.deinit();

                    _ = try inferParsedAttribute(expression, &label, attribute, context.subject);
                    case.truth = condition.boolean(&label);

                    context.labels.observe(case.truth);
                },
                .InferDefaultLabel => case.truth = try context.labels.remaining(context.cases[index + 1 ..]),
                .RefineSubject => {
                    facts = expression.nonnull.items.len;

                    if (case.truth) |present| {
                        try condition.assumeParsed(expression.graph.scratch, context.parsed, present, expression.conditionScope());
                    }
                },
                .InferBody => try self.steps(case.body),
                .RestoreFacts => expression.nonnull.shrinkRetainingCapacity(facts),
                .RestoreBindings => expression.bindings.shrinkRetainingCapacity(context.bindings),
                else => unreachable,
            }
        }
    }
    fn task(self: *Walker, comptime form: Schedule.Form, entry: *const Flow.Task, outputs: *Scope.Storage) zx.Error!void {
        const expression = self.expression;
        const graph = expression.graph;
        const bindings = expression.bindings.len;
        const parent_output = self.output;
        const parent_returned = self.returned;
        const offset = expression.span_offset + entry.node.location.offset;
        const span: zx.Span = .{ .start = offset, .end = offset };

        var output: ?Graph.Id = null;

        inline for (comptime Schedule.steps(form)) |step| {
            switch (step) {
                .Done => {},
                .EnterTask => {
                    output = try graph.add(.unknown, span);
                    self.output = output.?;
                    self.returned = false;
                },
                .InferBody => try self.steps(entry.body),
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
    fn call(self: *Walker, index: usize, outputs: *Scope.Storage) zx.Error!void {
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

                    for (invocation.getters) |getter| {
                        try expression.bindings.append(expression.scope, .{ .name = getter.name, .value = try graph.known(getter.slot.type_id, span) });
                    }
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
