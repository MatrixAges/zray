const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const Context = @import("../iteration_value/root.zig");
const evaluation = @import("../expressions/evaluate.zig");
const generated = @import("genz_options").generated_analysis;
const Consumer = @import("../iteration_consumer.zig").Consumer;
const Api = evaluation.Api;

const Plan = struct {
    preparation: enum { BufferedConsumer, DeepConsumer, Consumer, ConvertedConsumer, Unit, Reserve, Block, Layout, Pointer },
    completion: enum { Prepared, State, GuardPrepared, GuardState, GuardDeep, GuardConstruct },
};

const Preparation = @FieldType(Plan, "preparation");
pub const Mode = enum { reference, value, discard, consume };

pub const Prefix = struct {
    renewals: node.Block = .{},
    declarations: node.Block = .{},
    frame: node.Block = .{},
};

pub const Result = struct {
    consumer: ?Consumer,
    deep: bool,
    context: *Context,
    converted: bool,
    type_id: ir.TypeId,
    by_value: bool,
    local: bool,
    selected_state: bool,
    initial: node.ExpressionId,
    changed_name: []const u8,
    mode: Mode,
    pub fn lower(config: Result, self: *Lower, body: *Context.Statements, state: node.ExpressionId, previous: Prefix) Lower.Error!node.ExpressionId {
        const frame: Publication = .{
            .config = config,
            .lowering = self,
            .body = body,
            .state = state,
            .prefix = previous,
        };

        const actions = config.seedPlan();
        const prepared = try frame.prepare(actions.preparation);

        const guard = switch (actions.completion) {
            .Prepared, .State => null,
            else => try frame.guard(),
        };

        const value = switch (actions.completion) {
            .Prepared, .GuardPrepared => prepared,
            .State, .GuardState => state,
            .GuardDeep => try frame.convert(true),
            .GuardConstruct => try frame.convert(false),
        };

        return frame.publish(value, guard);
    }
    fn seedPlan(config: Result) Plan {
        if (config.consumer != null) {
            const action: Preparation = if (config.deep)
                if (config.context.inline_lists) .BufferedConsumer else .DeepConsumer

            else if (config.converted)
                .ConvertedConsumer
            else
                .Consumer;

            return .{ .preparation = action, .completion = .Prepared };
        }

        if (config.mode == .discard) return .{ .preparation = .Unit, .completion = .Prepared };

        const action: Preparation = if (config.converted)
            if (config.by_value) .Layout else .Pointer
        else
            .Block;

        const completion: @FieldType(Plan, "completion") = if (config.by_value)
            .Prepared

        else if (!config.local)
            .State
        else if (config.converted)
            .GuardPrepared
        else if (config.selected_state)
            .GuardState
        else if (config.deep)
            .GuardDeep
        else
            .GuardConstruct;

        return .{ .preparation = action, .completion = completion };
    }
};

const Publication = struct {
    config: Result,
    lowering: *Lower,
    body: *Context.Statements,
    state: node.ExpressionId,
    prefix: Prefix,
    fn prepare(self: *const Publication, action: Preparation) Lower.Error!node.ExpressionId {
        return switch (action) {
            .BufferedConsumer => self.deep(true),
            .DeepConsumer => self.deep(false),
            .Consumer => self.project(false),
            .ConvertedConsumer => self.project(true),
            .Unit => self.lowering.builder.expression(.unit),
            .Reserve => self.reserve(),
            .Block, .Layout, .Pointer => self.wrap(action),
        };
    }
    fn deep(self: *const Publication, buffered: bool) Lower.Error!node.ExpressionId {
        const consumer = self.config.consumer.?;

        return if (buffered)
            @import("../iteration_value/result.zig").buffered(self.config.context, self.body, consumer, self.state)
        else
            @import("../iteration_value/result.zig").lower(self.lowering, consumer, self.state);
    }
    fn project(self: *const Publication, converted: bool) Lower.Error!node.ExpressionId {
        return readProjection(self.lowering, self.body, self.config.consumer.?, self.state, converted);
    }
    fn reserve(self: *const Publication) Lower.Error!node.ExpressionId {
        const lowering = self.lowering;
        lowering.serial = std.math.add(usize, lowering.serial, 1) catch return error.OutOfMemory;

        return self.state;
    }
    fn wrap(self: *const Publication, action: Preparation) Lower.Error!node.ExpressionId {
        return wrapResult(self.lowering, self.config.type_id, self.state, action);
    }
    fn guard(self: *const Publication) Lower.Error!node.ExpressionId {
        return self.lowering.builder.identifier(self.config.changed_name);
    }
    fn convert(self: *const Publication, deep_result: bool) Lower.Error!node.ExpressionId {
        return if (deep_result)
            @import("../iteration_value/conversion.zig").convert(self.config.context, self.config.type_id, self.state, true)
        else
            self.lowering.construct(self.config.type_id, self.state);
    }
    fn publish(self: *const Publication, value: node.ExpressionId, condition: ?node.ExpressionId) Lower.Error!node.ExpressionId {
        const lowering = self.lowering;
        const previous = self.prefix;
        const appended = if (generated) try self.body.block(lowering.allocator) else try lowering.builder.statements(self.body.items);

        const final = try @import("../../node/blocks.zig").tail(
            lowering.allocator,
            lowering.builder.nodes,
            &.{ previous.renewals.start, previous.declarations.start, previous.frame.start, appended.start },
            &.{ previous.renewals.len, previous.declarations.len, previous.frame.len, appended.len },
        );

        return aggregate.finishStored(lowering, final, value, if (condition) |guard_id| .{ .condition = guard_id, .fallback = self.config.initial } else null);
    }
};

fn readProjection(lowering: *Lower, body: *Context.Statements, consumer: Consumer, state: node.ExpressionId, converted: bool) Lower.Error!node.ExpressionId {
    const value = try @import("../iteration_consumer.zig").read(lowering, consumer, consumer.result, state);

    if (!converted) return value;

    const bound = try aggregate.bind(lowering, body, value);
    const type_id = lowering.program.expression(consumer.result).type_id;

    return @import("../state_value/conversion.zig").convert(lowering, body, type_id, bound, .pointer);
}

fn wrapResult(lowering: *Lower, type_id: ir.TypeId, state: node.ExpressionId, action: Preparation) Lower.Error!node.ExpressionId {
    var inner: Context.Statements = if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;

    defer if (generated) inner.deinit();

    const value = if (action == .Block) state else try @import("../state_value/conversion.zig").convert(lowering, &inner, type_id, state, if (action == .Layout) .layout else .pointer);

    return aggregate.finish(lowering, &inner, value);
}

fn readConsumer(consumer: *const Api.LoopConsumer) Consumer {
    return .{ .symbol = @fromBackingInt(consumer.symbol), .result = @fromBackingInt(consumer.result), .layout = consumer.layout };
}

pub fn consumeDeepLoopResult(handle: *anyopaque, consumer: *const Api.LoopConsumer, state: u32) Lower.Error!u32 {
    return @backingInt(try @import("../iteration_value/result.zig").lower(evaluation.borrow(handle), readConsumer(consumer), @fromBackingInt(state)));
}

pub fn consumeBufferedLoopResult(allocator: std.mem.Allocator, handle: *anyopaque, consumer: *const Api.LoopConsumer, state: u32) Lower.Error!*const Api.LoopConsumption {
    const context: *Context = @ptrCast(@alignCast(handle));
    var body = context.lowering.builder.statementSequence(allocator);
    const result = try allocator.create(Api.LoopConsumption);
    const value = try @import("../iteration_value/result.zig").buffered(context, &body, readConsumer(consumer), @fromBackingInt(state));

    result.* = .{ .value = @backingInt(value), .spans = body.parts.items, .tail = body.last };

    return result;
}

pub fn consumeLoopProjection(allocator: std.mem.Allocator, handle: *anyopaque, consumer: *const Api.LoopConsumer, state: u32, converted: bool) Lower.Error!*const Api.LoopConsumption {
    const lowering = evaluation.borrow(handle);
    var body = lowering.builder.statementSequence(allocator);
    const result = try allocator.create(Api.LoopConsumption);
    const value = try readProjection(lowering, &body, readConsumer(consumer), @fromBackingInt(state), converted);

    result.* = .{ .value = @backingInt(value), .spans = body.parts.items, .tail = body.last };

    return result;
}

pub fn convertLoopResult(handle: *anyopaque, type_id: u32, state: u32, output: bool) Lower.Error!u32 {
    const context: *Context = @ptrCast(@alignCast(handle));

    return @backingInt(try @import("../iteration_value/conversion.zig").convert(context, @fromBackingInt(type_id), @fromBackingInt(state), output));
}
