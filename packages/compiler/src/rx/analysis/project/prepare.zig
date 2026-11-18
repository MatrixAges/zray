const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const target = @import("../call/target.zig");
const Libraries = @import("../call/library_bindings.zig");
const Inputs = @import("call_inputs.zig");
const Store = @import("../store.zig");
const StoreReferences = @import("../store/references.zig");
const Flow = @import("flow.zig");
const Action = rx.IndexedFlow.Operation;
const zx = @import("zx");
const Graph = @import("source_graph/model.zig");
const Signatures = @import("references/signatures.zig");
const generated = @import("rx_options").generated_graph;

comptime {
    if (generated) _ = @import("prepare/effects.zig");
}

pub const Callee = union(enum) { module: usize, signature: frontend.project.signature_project.Ports };
pub const batch_callees = generated and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64);
const CalleeInput = if (batch_callees) std.meta.Child(@import("generated_rx_mixed_callees").Input) else void;
const CalleeTargets = if (batch_callees) std.meta.Child(@FieldType(CalleeInput, "calls")) else void;
pub const CalleeKind = if (batch_callees) std.meta.Child(@FieldType(CalleeTargets, "kinds")) else enum(u8) { Source, AuthorizedSource, Compiled, NamedSource };

pub const Call = struct {
    setter: ?target.Setter = null,
    getters: []const Store.Binding = &.{},
    node: rx.ast.Node,
    input: ?*const rx.ast.Attribute,
    name_source: *const rx.ast.Attribute,
    target_kind: CalleeKind,
    target: usize,
    callee: Callee,
};

pub const Calls = std.MultiArrayList(Call);

pub const Module = struct {
    source: rx.ModuleSource,
    deferred_shortcut: bool = false,
    calls: Calls.Slice,
    plan: Flow.Plan,
    type_imports: []const zx.ir.Export = &.{},
    value_imports: frontend.expressions.BindingColumns = .{},
};

pub const Loaded = struct { modules: []Module, local_calls: []const bool, project: frontend.project.Options };
pub const Value = union(enum) { loaded: Loaded, diagnostic: target.Diagnostic };

pub fn loadSignatures(allocator: std.mem.Allocator, backing: std.mem.Allocator, modules: []const rx.ModuleSource, registered: []const []const Graph.Edge, initial_project: frontend.project.Options, definitions: []const Store.Definition, signatures: Signatures, inputs: *Inputs) std.mem.Allocator.Error!Value {
    const plans = try allocator.alloc(Module, modules.len);
    const local_calls = try allocator.alloc(bool, modules.len);

    var loader = Loader{
        .allocator = allocator,
        .backing = backing,
        .project = initial_project,
        .signatures = signatures,
        .inputs = inputs,
        .libraries = .{ .allocator = allocator, .scratch = std.heap.ArenaAllocator.init(backing) },
    };

    defer loader.libraries.scratch.deinit();

    var store_memory = std.heap.ArenaAllocator.init(backing);

    defer store_memory.deinit();

    var state: @import("prepare/modules/host.zig").State = .{
        .loader = &loader,
        .store_memory = &store_memory,
        .modules = modules,
        .registered = registered,
        .definitions = definitions,
        .plans = plans,
        .local_calls = local_calls,
    };

    state.load() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = state.loader.issue.? };
    };

    return .{ .loaded = .{ .modules = plans, .local_calls = local_calls, .project = loader.project } };
}

pub fn completeShortcuts(allocator: std.mem.Allocator, modules: []Module, signatures: []const @import("signatures.zig").Signature) std.mem.Allocator.Error!void {
    const shorthand = @import("shorthand.zig");
    var first: usize = 0;

    while (first < modules.len) {
        const row = shorthand.nextDeferred(modules, first) orelse break;
        const module = &modules[row];
        const signature = &signatures[row];
        const index = shorthand.call_index;
        const plan = try shorthand.lower(allocator, module.calls.items(.node)[index], index, signature.input_type, signature.output_type);

        module.calls.items(.node)[index] = plan.node;
        module.calls.items(.input)[index] = plan.input;

        module.plan = plan.flow;
        first = row + 1;
    }
}

pub const Loader = struct {
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    project: frontend.project.Options,
    signatures: Signatures,
    libraries: Libraries,
    inputs: *Inputs,
    arguments: std.ArrayList(?*const frontend.ExpressionInput.Result) = .empty,
    references: Graph.References = .{},
    owner: []const u8 = "",
    stores: StoreReferences.Scope = .{},
    calls: Calls = .empty,
    local_calls: bool = true,
    plan: Flow.Builder = .{},
    task_count: usize = 0,
    deferred_shortcut: bool = false,
    omitted_inputs: bool = false,
    issue: ?target.Diagnostic = null,
    pub const Error = std.mem.Allocator.Error || error{InvalidFlow};

    fn shortcut(self: *Loader, node: rx.ast.Node) Error!Flow.Plan {
        const shorthand = @import("shorthand.zig");
        const invocation = shorthand.call(node);
        const index = try self.call(invocation);

        std.debug.assert(index == shorthand.call_index);

        const callee = self.calls.items(.callee)[index];

        const ports = switch (callee) {
            .signature => |signature| signature,
            .module => {
                self.deferred_shortcut = true;

                return .{};
            },
        };

        const plan = try shorthand.lower(self.allocator, invocation, index, ports.input_type, ports.output_type);

        self.calls.items(.node)[index] = plan.node;
        self.calls.items(.input)[index] = plan.input;

        return plan.flow;
    }
    pub fn moduleBody(self: *Loader, source: rx.ModuleSource) Error!Flow.Plan {
        const node = source.node;

        if (target.optionalAttribute(node, "fn") != null) return self.shortcut(node);

        if (comptime generated) {
            if (source.indexedFlow()) |flow| return @import("prepare/indexed.zig").bind(self, flow);
        }

        const root = Flow.Unit{ .first = try self.plan.reserve(self.allocator, node.children.len) };
        const sequence = try self.steps(node.children, root);

        return self.plan.finish(sequence.unit);
    }
    fn unit(self: *Loader, count: usize) Error!Flow.Unit {
        return .{ .first = try self.plan.reserve(self.allocator, count) };
    }
    fn steps(self: *Loader, nodes: []const rx.ast.Node, region: Flow.Unit) Error!Flow.Sequence {
        var sequence: Flow.Sequence = .{ .unit = region };
        var cursor = region.first;

        for (nodes) |*node| {
            const action = seedAction(node.name);

            if (action == .declaration) continue;
            if (sequence.exits.terminates) return self.fail(node.location, "return_path", "steps after a terminating Return, Switch or If are unreachable");

            var exits: Flow.Exits = .{};

            const value: Flow.Operation = switch (action) {
                .result => result: {
                    exits = Flow.Exits.returned;

                    break :result .{ .Result = target.attribute(node.*, "value") };
                },
                .call => .{ .Call = try self.call(node.*) },
                .task => task: {
                    const output = target.optionalAttribute(node.*, "out");
                    const body = try self.taskBody(node, output, false);

                    exits = body.exits;

                    break :task .{ .Task = .{ .node = node, .body = body.unit, .output = output } };
                },
                .parallel => .{ .Parallel = try self.parallel(node) },
                .switch_flow, .if_flow => selection: {
                    const subject = target.borrowAttribute(node.*, "on").?;
                    var branches: Flow.BranchExits = .{};
                    const cases = if (action == .switch_flow) try self.switchCases(node.*, &branches) else try self.ifCases(node, subject, &branches);

                    exits = branches.finish();

                    break :selection .{ .Selection = .{ .subject = subject, .cases = cases } };
                },
                else => return self.fail(node.location, "unsupported", "RX execution supports Store declarations, Call, Return, Task, Switch, If and pure Parallel branches; events require host linking"),
            };

            try self.plan.write(self.allocator, cursor, value);

            cursor += 1;

            sequence.exits.advance(exits);
        }

        sequence.unit.count = cursor - region.first;

        return sequence;
    }
    fn switchCases(self: *Loader, node: rx.ast.Node, exits: *Flow.BranchExits) Error![]Flow.Case {
        const cases = try self.allocator.alloc(Flow.Case, node.children.len);

        for (node.children, cases) |*child, *case| {
            const default = rx.execution.admit(child.name, .Any) == .Default;

            const label: Flow.Case.Label = if (default) .{ .kind = .Default } else .{
                .kind = .Case,
                .source = target.borrowAttribute(child.*, "value").?,
            };

            case.* = try self.selectionCase(label, child.children, exits);
        }

        return cases;
    }
    fn ifCases(self: *Loader, node: *const rx.ast.Node, subject: *const rx.ast.Attribute, exits: *Flow.BranchExits) Error![]Flow.Case {
        const last = &node.children[node.children.len - 1];
        const has_else = rx.execution.admit(last.name, .Any) == .Else;
        const body = if (has_else) node.children[0 .. node.children.len - 1] else node.children;
        const cases = try self.allocator.alloc(Flow.Case, if (has_else) 2 else 1);

        cases[0] = try self.selectionCase(.{ .kind = .Affirmative, .source = subject }, body, exits);

        if (has_else) cases[1] = try self.selectionCase(.{ .kind = .Default }, last.children, exits);

        return cases;
    }
    fn selectionCase(self: *Loader, label: Flow.Case.Label, nodes: []const rx.ast.Node, exits: *Flow.BranchExits) Error!Flow.Case {
        const body = try self.steps(nodes, try self.unit(nodes.len));

        exits.add(label.kind == .Default, body.exits);

        return .{ .label = label, .body = body.unit };
    }
    fn parallel(self: *Loader, node: *const rx.ast.Node) Error!Flow.Unit {
        const branches = try self.unit(node.children.len);

        for (node.children, 0..) |*child, position| {
            const row = branches.first + @as(u32, @intCast(position));
            const action = seedAction(child.name);

            if (action == .call) {
                const call_index = try self.call(child.*);

                try self.plan.write(self.allocator, row, .{ .Call = call_index });

                continue;
            }

            const id = self.nextTaskId();
            const body = try self.taskBody(child, target.optionalAttribute(child.*, "out"), true);

            try self.plan.write(self.allocator, row, .{ .ParallelTask = .{ .id = id, .node = child, .body = body.unit } });
        }

        return .{ .first = branches.first, .count = @intCast(node.children.len) };
    }
    fn nextTaskId(self: *Loader) usize {
        const id = self.task_count;

        self.task_count += 1;

        return id;
    }
    fn taskBody(self: *Loader, node: *const rx.ast.Node, output: ?rx.ast.Attribute, parallel_task: bool) Error!Flow.Sequence {
        const has_implicit_result = parallel_task and output != null;
        const count = node.children.len + @intFromBool(has_implicit_result);
        const region = try self.unit(count);
        var body = try self.steps(node.children, region);
        const attribute = output orelse return body;

        if (body.exits.returns) return self.fail(attribute.value_location, "return_path", "Task.out and Return cannot both define the same task output");

        if (parallel_task) {
            try self.plan.write(self.allocator, body.unit.first + body.unit.count, .{ .Result = attribute });

            body.unit.count += 1;

            body.exits.advance(Flow.Exits.returned);
        }

        return body;
    }
    pub fn call(self: *Loader, node: rx.ast.Node) Error!usize {
        var state: @import("prepare/invocation/host.zig").State = .{
            .loader = self,
            .node = node,
            .index = self.calls.len,
        };

        try state.bind();

        return state.index;
    }

    pub fn recordArgument(self: *Loader, index: usize, parsed: *const frontend.ExpressionInput.Result) Error!void {
        const first = self.arguments.items.len;

        if (index >= first) {
            try self.arguments.resize(self.inputs.arena.allocator(), index + 1);

            @memset(self.arguments.items[first..index], null);
        }

        self.arguments.items[index] = parsed;
    }

    pub fn sourceCallee(self: *Loader, source: usize, location: rx.ast.Location, setter: bool) Error!Callee {
        const resolved = switch (self.signatures.lookup(source)) {
            .rx => |index| return .{ .module = index },
            .store => return self.fail(location, "module", "Call.module target is not registered"),
            .zx => |signature| signature orelse return self.fail(location, "module", "source function signature is missing from the analyzed input set"),
        };

        const signature = resolved.module.signature;
        const forwarded = resolved.forward;

        return switch (routeSignature(forwarded != .none, signature.type_only, setter, signature.has_store)) {
            .Function => .{ .signature = signature.ports },
            .Forward => if (forwarded == .module) .{ .module = forwarded.module } else self.fail(location, "module", "default re-export target is missing from the RX module collection"),
            .SetterOnForward => self.fail(location, "capability", "RX module Store authorization belongs inside the module"),
            .TypeOnly => self.fail(location, "module", "Call.fn requires an executable ZX module with a default function"),
            .MissingStore => self.fail(location, "capability", "a Call.setter target must declare its second parameter as { store }"),
        };
    }
    pub fn namedCallee(self: *Loader, source: usize, selection: *const rx.ast.Attribute) Error!Callee {
        const signature = switch (self.signatures.lookup(source)) {
            .zx => |value| if (value) |resolved| resolved.module.signature else return self.fail(selection.value_location, "module", "source function signature is missing from the analyzed input set"),
            else => return self.fail(selection.value_location, "module", "a qualified Call.fn requires a ZX source module"),
        };

        const name = @import("../result_name.zig").resolveCall(selection.*).name;

        for (signature.members) |*member| {
            if (!std.mem.eql(u8, member.name, name)) continue;
            if (member.has_store) return self.fail(selection.value_location, "capability", "a named Call cannot invoke a Store transaction");
            if (member.kind != .callable) break;

            return .{ .signature = member.ports };
        }

        return self.fail(selection.value_location, "module", "ZX source does not export the selected callable function");
    }
    pub fn compiledCallee(self: *Loader, location: rx.ast.Location, selected: frontend.project.compiled.Target, setter: bool) Error!Callee {
        const result = try self.libraries.bind(&self.project, .{
            .owner = self.owner,
            .location = location,
            .setter = setter,
            .selected = selected,
        });

        if (result == .diagnostic) {
            self.issue = result.diagnostic;

            return error.InvalidFlow;
        }

        return .{ .signature = result.ports };
    }
    pub fn fail(self: *Loader, location: rx.ast.Location, code: []const u8, message: []const u8) Error {
        const result = try target.failure(self.allocator, .{ .path = self.owner, .location = location, .code = code, .message = message });

        self.issue = result.diagnostic;

        return error.InvalidFlow;
    }
};

fn seedAction(name: []const u8) Action {
    return switch (rx.execution.admit(name, .Any)) {
        .Import, .Store, .Type, .Args => .declaration,
        .Return => .result,
        .Call => .call,
        .Task => .task,
        .Parallel => .parallel,
        .Switch => .switch_flow,
        .If => .if_flow,
        else => .unsupported,
    };
}

const SignatureRoute = if (generated)
    @typeInfo(@TypeOf(@import("generated_rx_call_signature").executeValue(undefined, undefined))).error_union.payload

else
    enum { Function, Forward, SetterOnForward, TypeOnly, MissingStore };

fn routeSignature(forwards_rx: bool, type_only: bool, setter: bool, has_store: bool) SignatureRoute {
    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const rule = @import("generated_rx_call_signature");
        const input: std.meta.Child(rule.Input) = .{ .forwards_rx = forwards_rx, .type_only = type_only, .setter = setter, .has_store = has_store };

        return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    }

    if (forwards_rx) return if (setter) .SetterOnForward else .Forward;
    if (type_only) return .TypeOnly;
    if (setter and !has_store) return .MissingStore;

    return .Function;
}
