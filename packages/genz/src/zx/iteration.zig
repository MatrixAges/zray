const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const frame = @import("iteration/frame.zig");
const renewal = @import("iteration/renewal.zig");
const state_declaration = @import("iteration/state.zig");
const step = @import("iteration/step.zig");
const Context = @import("iteration_value/root.zig");
const generated = @import("genz_options").generated_analysis;
const scope = @import("state_value/scope.zig");

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

pub fn consume(self: *Lower, id: ir.ExprId, consumer: @import("iteration_consumer.zig").Consumer) Lower.Error!?node.ExpressionId {
    return lowerMode(self, id, self.program.expression(id).value.iteration, .consume, consumer);
}

const Mode = @import("iteration/result.zig").Mode;

fn lowerMode(self: *Lower, id: ir.ExprId, iteration: ir.Iteration, mode: Mode, consumer: ?@import("iteration_consumer.zig").Consumer) Lower.Error!?node.ExpressionId {
    const projected_output = if (consumer) |selected| try @import("iteration_value/result.zig").candidate(self.allocator, self.program, selected) else false;
    var body: Context.Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;
    var loop: Context.Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;

    defer if (generated) body.deinit();
    defer if (generated) loop.deinit();

    const name = try self.fresh("state");
    const state = try self.builder.identifier(name);
    const selection = try @import("iteration_layout/select.zig").choose(self, id, iteration, mode, consumer, projected_output);

    switch (selection.representation) {
        .dereference => return try self.builder.expression(.{ .dereference = try lower(self, id, iteration) }),
        .reject => return null,
        else => {},
    }

    const selected_call = selection.forwarded;
    const type_id = self.program.expression(id).type_id;

    const preparation = @import("iteration/initial.zig").plan(.{
        .representation = selection.representation,
        .mode = mode,
        .state_active = self.state_active,
        .direct_initial = selection.direct_initial,
        .postcondition = iteration.postcondition,
        .consumer = consumer != null,
        .pure = selection.pure,
        .forwarded = selected_call != null,
    });

    var context = Context{ .lowering = self, .declarations = &body, .inline_lists = preparation.buffered };

    const initial_expression = switch (preparation.evaluation) {
        .Reference => try self.expr(iteration.initial),
        .Value => try @import("value_call/root.zig").expression(self, iteration.initial),
        .Deep => initial: {
            const view = scope.enter(self, .Iteration, .{ .iteration_value = &context });

            defer view.restore();

            break :initial try self.expr(iteration.initial);
        },
    };

    const initial = if (preparation.local) try aggregate.bind(self, &body, initial_expression) else initial_expression;

    var initial_guard: ?@import("iteration_value/initial.zig") = if (preparation.guard != .None)
        try @import("iteration_value/initial.zig").create(self, &body, iteration, consumer, initial, preparation.guard)
    else
        null;

    const state_scope = if (preparation.state_scope) try @import("state_value/root.zig").enter(self) else null;

    defer if (state_scope) |saved| saved.restore();

    const seed = try self.builder.identifier(try self.fresh("loop_seed"));
    var fields = if (preparation.project_fields) try @import("iteration/fields/prepare.zig").prepare(self, iteration, type_id, &body, seed) else null;
    const changed_name = if (preparation.track) try self.fresh("state_changed") else "";
    const tracking = if (changed_name.len != 0) changed_name else null;
    const parameters = try @import("iteration/parameters.zig").enter(self, iteration, preparation.parameters, name, &context);

    defer parameters.restore();

    const finish = @import("iteration/result.zig").Result{
        .consumer = consumer,
        .deep = preparation.deep,
        .context = &context,
        .converted = preparation.state_scope,
        .type_id = type_id,
        .by_value = preparation.by_value,
        .local = preparation.local,
        .selected_state = preparation.selected_state,
        .initial = initial,
        .changed_name = changed_name,
        .mode = mode,
    };

    const initial_state = switch (preparation.storage) {
        .Keep => initial,
        .Dereference => try @import("access/emit.zig").dereference(self, initial),
        .Deep => try @import("iteration_value/conversion.zig").convert(&context, type_id, initial, false),
        .State, .StateValue => try @import("state_value/conversion.zig").convert(self, &body, type_id, initial, if (preparation.storage == .StateValue) .value_layout else .value),
        .Clip => try @import("state_value/ownership.zig").clip(self, &body, iteration.initial, initial),
    };

    var renewal_scope = std.heap.ArenaAllocator.init(self.workspace);
    var renewal_buffer: [256]u8 = undefined;
    var renewal_memory = std.heap.BufferFirstAllocator.init(&renewal_buffer, renewal_scope.allocator());

    defer renewal_scope.deinit();

    const temporary = renewal_memory.allocator();

    const schedule = step.plan(.{
        .condition = @backingInt(iteration.condition),
        .body = @backingInt(iteration.body),
        .forwarded = if (selected_call) |call| @backingInt(call) else null,
        .postcondition = iteration.postcondition,
        .projected = fields != null,
        .selected_state = preparation.selected_state,
        .layout = preparation.layout,
        .buffered = preparation.buffered,
        .discard = mode == .discard,
    });

    const renewals = try renewal.plan(self, temporary, .{
        .owner = id,
        .type_id = type_id,
        .classify = if (schedule.classify_renewals) iteration else null,
        .inline_lists = schedule.inline_lists,
    });

    if (fields) |*selected| {
        const renewed = renewals.needsEntries(self);
        const seed_name = self.builder.nodes.get(seed).identifier;

        const tracker = try state_declaration.declare(self, &body, .{
            .name = seed_name,
            .layout = try self.layoutExpr(type_id),
            .initial = initial_state,
            .mutable = renewed,
            .tracking = tracking,
        });

        const next = try step.lower(self, schedule, &parameters, .{ .projected = .{
            .fields = selected,
            .name = name,
            .seed = seed_name,
        } });

        var entered: Context.Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;

        defer if (generated) entered.deinit();

        const growth = try renewals.store(self, type_id, .{ .reference = seed });

        try selected.maskBorrowed(self, &entered);

        _ = try state_declaration.declare(self, &entered, .{
            .name = name,
            .layout = selected.layout,
            .initial = try selected.initial(self),
        });

        const prefix = if (generated) try entered.block(self.allocator) else try self.builder.statements(entered.items);

        const update = try step.store(self, &loop, schedule, .{
            .type_id = type_id,
            .origin = iteration.body,
            .target = state,
            .value = next.value,
            .fields = selected,
        }, tracker);

        const framed = try frame.lower(self, .{}, update, .{ .condition = next.condition, .after_step = schedule.after_step });

        entered.clearRetainingCapacity();

        const restored = if (schedule.restore_projected) try aggregate.bind(self, &entered, try selected.restore(self, state)) else state;
        const result = try finish.lower(self, &entered, restored, .{ .renewals = growth, .declarations = prefix, .frame = framed });

        if (next.first) |first| {
            var skipped: Context.Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;

            defer if (generated) skipped.deinit();

            return try aggregate.finishGuarded(self, &body, first, result, try finish.lower(self, &skipped, seed, .{}));
        }

        return try aggregate.finish(self, &body, result);
    }

    const next = try step.lower(self, schedule, &parameters, .{ .ordinary = renewals.delayed });

    const tracker = try state_declaration.declare(self, &body, .{
        .name = name,
        .layout = switch (preparation.parameters) {
            .Plain => try self.typeExpr(type_id),
            .Stack, .State => try self.layoutExpr(type_id),
            .Deep => try @import("iteration_value/types.zig").get(&context, type_id),
        },
        .initial = initial_state,
        .tracking = tracking,
    });

    const entered = try renewals.store(self, type_id, .{ .reference = state });
    const prefix = if (generated) try body.block(self.allocator) else try self.builder.statements(body.items);

    const update = try step.store(self, &loop, schedule, .{
        .type_id = type_id,
        .origin = iteration.body,
        .target = state,
        .value = next.value,
    }, tracker);

    const framed = try frame.lower(self, entered, update, .{
        .condition = next.condition,
        .after_step = schedule.after_step,
        .guarded_initial = initial_guard != null,
    });

    body.clearRetainingCapacity();

    const result = try finish.lower(self, &body, state, .{ .declarations = prefix, .frame = framed });

    if (initial_guard) |*guard| return try guard.finish(self, result);

    return result;
}
