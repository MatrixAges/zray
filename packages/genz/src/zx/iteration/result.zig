const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const Context = @import("../iteration_value/root.zig");
const evaluation = @import("../expressions/evaluate.zig");
const generated = @import("genz_options").generated_analysis;

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
    consumer: ?@import("../iteration_consumer.zig").Consumer,
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

        if (generated) {
            const execute = @import("generated_publish_loop_result");
            const Input = std.meta.Child(execute.Input);
            const publication = @import("../construction/publication.zig");
            var origin: publication.OriginBuffer = .{};

            const input: Input = .{
                .target = @ptrCast(&frame),
                .frame = @ptrCast(self),
                .writer = @ptrCast(self),
                .origin = @ptrCast(&origin),
                .body = @ptrCast(body),
                .changed_name = config.changed_name,
                .type_id = @backingInt(config.type_id),
                .state = @backingInt(state),
                .initial = @backingInt(config.initial),
                .renewals = publication.packSpan(previous.renewals),
                .declarations = publication.packSpan(previous.declarations),
                .frame_span = publication.packSpan(previous.frame),
                .facts = &.{
                    .consumer = config.consumer != null,
                    .deep = config.deep,
                    .inline_lists = config.context.inline_lists,
                    .converted = config.converted,
                    .discard = config.mode == .discard,
                    .by_value = config.by_value,
                    .local = config.local,
                    .selected = config.selected_state,
                },
            };

            return evaluation.invokeWith(self, execute, &input);
        }

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
    fn borrow(target: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(target));
    }
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
        const lowering = self.lowering;
        const consumer = self.config.consumer.?;
        const value = try @import("../iteration_consumer.zig").read(lowering, consumer, consumer.result, self.state);

        if (!converted) return value;

        const bound = try aggregate.bind(lowering, self.body, value);
        const type_id = lowering.program.expression(consumer.result).type_id;

        return @import("../state_value/conversion.zig").convert(lowering, self.body, type_id, bound, .pointer);
    }
    fn reserve(self: *const Publication) Lower.Error!node.ExpressionId {
        const lowering = self.lowering;
        lowering.serial = std.math.add(usize, lowering.serial, 1) catch return error.OutOfMemory;

        return self.state;
    }
    fn wrap(self: *const Publication, action: Preparation) Lower.Error!node.ExpressionId {
        const lowering = self.lowering;
        var inner: Context.Statements = if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;

        defer if (generated) inner.deinit();

        const value = if (action == .Block) self.state else try @import("../state_value/conversion.zig").convert(lowering, &inner, self.config.type_id, self.state, if (action == .Layout) .layout else .pointer);

        return aggregate.finish(lowering, &inner, value);
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

pub fn consumeDeepLoopResult(handle: *const anyopaque, buffered: bool) Lower.Error!u32 {
    return @backingInt(try Publication.borrow(handle).deep(buffered));
}

pub fn consumeLoopProjection(handle: *const anyopaque, converted: bool) Lower.Error!u32 {
    return @backingInt(try Publication.borrow(handle).project(converted));
}

pub fn wrapLoopResult(handle: *const anyopaque, layout: bool) Lower.Error!u32 {
    return @backingInt(try Publication.borrow(handle).wrap(if (layout) .Layout else .Pointer));
}

pub fn convertLoopResult(handle: *const anyopaque) Lower.Error!u32 {
    return @backingInt(try Publication.borrow(handle).convert(true));
}
