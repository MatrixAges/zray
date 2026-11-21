const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const frame = @import("iteration/frame.zig");
const renewal = @import("iteration/renewal.zig");
const initial = @import("iteration/initial.zig");
const result = @import("iteration/result.zig");
const state_declaration = @import("iteration/state.zig");
const step = @import("iteration/step.zig");
const Parameters = @import("iteration/parameters.zig");
const Fields = @import("iteration/fields/root.zig");
const InitialGuard = @import("iteration_value/initial.zig");
const Context = @import("iteration_value/root.zig");
const Consumer = @import("iteration_consumer.zig").Consumer;
const generated = @import("genz_options").generated_analysis;
const scope = @import("state_value/scope.zig");
const workflow = @import("iteration/workflow.zig");

pub fn lower(self: *Lower, id: ir.ExprId, iteration: ir.Iteration) Lower.Error!node.ExpressionId {
    return (try lowerMode(self, id, iteration, .reference, null)).?;
}

pub fn lowerValue(self: *Lower, id: ir.ExprId, iteration: ir.Iteration) Lower.Error!node.ExpressionId {
    return (try lowerMode(self, id, iteration, .value, null)).?;
}

pub fn discard(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const value = self.program.expression(id).value;

    if (value != .iteration) return self.expr(id);

    return (try lowerMode(self, id, value.iteration, .discard, null)).?;
}

pub fn consume(self: *Lower, id: ir.ExprId, consumer: Consumer) Lower.Error!?node.ExpressionId {
    return lowerMode(self, id, self.program.expression(id).value.iteration, .consume, consumer);
}

fn lowerMode(self: *Lower, id: ir.ExprId, iteration: ir.Iteration, mode: result.Mode, consumer: ?Consumer) Lower.Error!?node.ExpressionId {
    const projected_output = if (consumer) |selected| try @import("iteration_value/result.zig").candidate(self.allocator, self.program, selected) else false;
    var body: Context.Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;
    var loop: Context.Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;

    defer if (generated) body.deinit();
    defer if (generated) loop.deinit();

    const selection_module = @import("iteration_layout/select.zig");
    var name: []const u8 = undefined;
    var state: node.ExpressionId = undefined;
    var type_id: ir.TypeId = undefined;
    var selection: selection_module.Selection = undefined;
    var preparation: initial.Plan = undefined;
    var context: Context = undefined;
    var initial_value: node.ExpressionId = undefined;
    var guard: ?InitialGuard = null;

    inline for (comptime workflow.steps(.Open)) |action| switch (action) {
        .CreateState => {
            name = try self.fresh("state");
            state = try self.builder.identifier(name);
        },
        .Select => {
            selection = try selection_module.choose(self, id, iteration, mode, consumer, projected_output);

            switch (selection.representation) {
                .dereference => return try self.builder.expression(.{ .dereference = try lower(self, id, iteration) }),
                .reject => return null,
                else => {},
            }
        },
        .Prepare => {
            type_id = @fromBackingInt(self.program.expressions.types[@backingInt(id)]);

            preparation = initial.plan(.{
                .representation = selection.representation,
                .mode = mode,
                .state_active = self.state_active,
                .direct_initial = selection.direct_initial,
                .postcondition = iteration.postcondition,
                .consumer = consumer != null,
                .pure = selection.pure,
                .forwarded = selection.forwarded != null,
            });

            context = .{ .lowering = self, .declarations = &body, .inline_lists = preparation.buffered };
        },
        .EvaluateInitial => {
            const value = switch (preparation.evaluation) {
                .Reference => try self.expr(iteration.initial),
                .Value => try @import("value_call/root.zig").expression(self, iteration.initial),
                .Deep => deep: {
                    const view = scope.enter(self, .Iteration, .{ .iteration_value = &context });

                    defer view.restore();

                    break :deep try self.expr(iteration.initial);
                },
            };

            initial_value = if (preparation.local) try aggregate.bind(self, &body, value) else value;
        },
        .GuardInitial => if (preparation.guard != .None) {
            guard = try InitialGuard.create(self, &body, iteration, consumer, initial_value, preparation.guard);
        },
        else => @compileError("Invalid loop opening step"),
    };

    const representation = if (preparation.state_scope) try @import("state_value/root.zig").enter(self) else null;

    defer if (representation) |saved| saved.restore();

    var seed: node.ExpressionId = undefined;
    var fields: ?Fields = null;
    var changed_name: []const u8 = undefined;

    inline for (comptime workflow.steps(.StateScope)) |action| switch (action) {
        .PrepareFields => {
            seed = try self.builder.identifier(try self.fresh("loop_seed"));

            if (preparation.project_fields) fields = try @import("iteration/fields/prepare.zig").prepare(self, iteration, type_id, &body, seed);
        },
        .TrackChanges => changed_name = if (preparation.track) try self.fresh("state_changed") else "",
        else => @compileError("Invalid loop state preparation step"),
    };

    const parameters = try Parameters.enter(self, iteration, preparation.parameters, name, &context);

    defer parameters.restore();

    const finish: result.Result = .{
        .consumer = consumer,
        .deep = preparation.deep,
        .context = &context,
        .converted = preparation.state_scope,
        .type_id = type_id,
        .by_value = preparation.by_value,
        .local = preparation.local,
        .selected_state = preparation.selected_state,
        .initial = initial_value,
        .changed_name = changed_name,
        .mode = mode,
    };

    var renewal_scope = std.heap.ArenaAllocator.init(self.workspace);
    var renewal_buffer: [256]u8 = undefined;
    var renewal_memory = std.heap.BufferFirstAllocator.init(&renewal_buffer, renewal_scope.allocator());

    defer renewal_scope.deinit();

    var initial_state: node.ExpressionId = undefined;
    var schedule: step.Plan = undefined;
    var renewals: renewal.Plan = undefined;

    inline for (comptime workflow.steps(.Parameters)) |action| switch (action) {
        .ConvertInitial => initial_state = switch (preparation.storage) {
            .Keep => initial_value,
            .Dereference => try @import("access/emit.zig").dereference(self, initial_value),
            .Deep => try @import("iteration_value/conversion.zig").convert(&context, type_id, initial_value, false),
            .State, .StateValue => try @import("state_value/conversion.zig").convert(self, &body, type_id, initial_value, if (preparation.storage == .StateValue) .value_layout else .value),
            .Clip => try @import("state_value/ownership.zig").clip(self, &body, iteration.initial, initial_value),
        },
        .Schedule => schedule = step.plan(.{
            .condition = @backingInt(iteration.condition),
            .body = @backingInt(iteration.body),
            .forwarded = if (selection.forwarded) |call| @backingInt(call) else null,
            .postcondition = iteration.postcondition,
            .projected = fields != null,
            .selected_state = preparation.selected_state,
            .layout = preparation.layout,
            .buffered = preparation.buffered,
            .discard = mode == .discard,
        }),
        .Renewals => renewals = try renewal.plan(self, renewal_memory.allocator(), .{
            .owner = id,
            .type_id = type_id,
            .classify = if (schedule.classify_renewals) iteration else null,
            .inline_lists = schedule.inline_lists,
        }),
        else => @compileError("Invalid loop parameter step"),
    };

    const request: Emission = .{
        .parameters = &parameters,
        .finish = &finish,
        .schedule = &schedule,
        .renewals = &renewals,
        .parameter_layout = preparation.parameters,
        .name = name,
        .state = state,
        .seed = seed,
        .initial = initial_state,
        .origin = iteration.body,
    };

    if (fields) |*selected| return try emit(self, &body, &loop, request, .projected, selected);

    return try emit(self, &body, &loop, request, .ordinary, &guard);
}

const Emission = struct {
    parameters: *const Parameters,
    finish: *const result.Result,
    schedule: *const step.Plan,
    renewals: *const renewal.Plan,
    parameter_layout: Parameters.Layout,
    name: []const u8,
    state: node.ExpressionId,
    seed: node.ExpressionId,
    initial: node.ExpressionId,
    origin: ir.ExprId,
};

const Branch = enum {
    ordinary,
    projected,
};

fn emit(self: *Lower, body: *Context.Statements, loop: *Context.Statements, request: Emission, comptime branch: Branch, payload: if (branch == .projected) *Fields else *?InitialGuard) Lower.Error!node.ExpressionId {
    const projected = branch == .projected;
    const type_id = request.finish.type_id;
    const changed_name = request.finish.changed_name;
    const tracking = if (changed_name.len != 0) changed_name else null;

    var entered: if (projected) Context.Statements else void = if (!projected)
        {}

    else if (generated)
        self.builder.statementSequence(self.workspace)
    else
        .empty;

    defer if (generated and projected) entered.deinit();

    const output = if (projected) &entered else body;
    var next: step.Values = undefined;
    var tracker: ?state_declaration.Tracker = undefined;
    var prefix: result.Prefix = .{};
    var update: node.Block = undefined;
    var growth: node.Block = undefined;
    var recovered = request.state;

    inline for (comptime workflow.steps(if (projected) .Projected else .Ordinary)) |action| switch (action) {
        .EvaluateStep => next = try step.lower(self, request.schedule.*, request.parameters, if (projected)
            .{ .projected = .{
                .fields = payload,
                .name = request.name,
                .seed = self.builder.nodes.get(request.seed).identifier,
            } }
        else
            .{ .ordinary = request.renewals.delayed }),
        .Declare => {
            const name = if (projected) self.builder.nodes.get(request.seed).identifier else request.name;
            const mutable = if (projected) request.renewals.needsEntries(self) else true;

            const layout = if (projected) try self.layoutExpr(type_id) else switch (request.parameter_layout) {
                .Plain => try self.typeExpr(type_id),
                .Stack, .State => try self.layoutExpr(type_id),
                .Deep => try @import("iteration_value/types.zig").get(request.finish.context, type_id),
            };

            tracker = try state_declaration.declare(self, body, .{
                .name = name,
                .layout = layout,
                .initial = request.initial,
                .mutable = mutable,
                .tracking = tracking,
            });
        },
        .EnterLoop => {
            growth = try request.renewals.store(self, type_id, .{ .reference = if (projected) request.seed else request.state });

            if (projected) {
                try payload.maskBorrowed(self, output);

                _ = try state_declaration.declare(self, output, .{
                    .name = request.name,
                    .layout = payload.layout,
                    .initial = try payload.initial(self),
                });
            }
        },
        .SavePrefix => prefix.declarations = if (generated) try output.block(self.allocator) else try self.builder.statements(output.items),
        .WriteUpdate => update = try step.store(self, loop, request.schedule.*, .{
            .type_id = type_id,
            .origin = request.origin,
            .target = request.state,
            .value = next.value,
            .fields = if (projected) payload else null,
        }, tracker),
        .Frame => {
            prefix.renewals = if (projected) growth else .{};

            prefix.frame = try frame.lower(self, if (projected) .{} else growth, update, .{
                .condition = next.condition,
                .after_step = request.schedule.after_step,
                .guarded_initial = if (projected) false else payload.* != null,
            });
        },
        .Recover => {
            output.clearRetainingCapacity();

            if (projected and request.schedule.restore_projected) {
                recovered = try aggregate.bind(self, output, try payload.restore(self, request.state));
            }
        },
        .Finish => {
            const value = try request.finish.lower(self, output, recovered, prefix);

            if (projected) {
                if (next.first) |first| {
                    var skipped: Context.Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;

                    defer if (generated) skipped.deinit();

                    return aggregate.finishGuarded(self, body, first, value, try request.finish.lower(self, &skipped, request.seed, .{}));
                }

                return aggregate.finish(self, body, value);
            }

            if (payload.*) |*guard| return guard.finish(self, value);

            return value;
        },
        else => @compileError("Invalid loop execution step"),
    };

    unreachable;
}
