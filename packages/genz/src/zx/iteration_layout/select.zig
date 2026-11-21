const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const layout = @import("../iteration_layout.zig");
const consumers = @import("../iteration_consumer.zig");
const evaluation = @import("../expressions/evaluate.zig");
const generated = @import("genz_options").generated_analysis;
const Mode = @import("../iteration/result.zig").Mode;
pub const Representation = enum { plain, stack, state, deep, buffered, dereference, reject };

pub const Selection = struct {
    representation: Representation,
    forwarded: ?ir.ExprId = null,
    pure: bool = false,
    direct_initial: bool = false,
};

const model = if (generated) @import("generated_iteration_layout_selection") else void;
const Input = if (generated) std.meta.Child(model.Input) else void;
const Action = if (generated) evaluation.Api.LayoutAction else void;

const Frame = struct {
    lowering: *Lower,
    iteration: ir.Iteration,
    consumer: ?consumers.Consumer,
    type_id: ir.TypeId,
    facts: Input,
    forwarded: ?ir.ExprId = null,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn choose(self: *Lower, id: ir.ExprId, iteration: ir.Iteration, mode: Mode, consumer: ?consumers.Consumer, projected_output: bool) Lower.Error!Selection {
    if (comptime !generated) {
        return @import("select_seed.zig").choose(self, id, iteration, mode, consumer, projected_output);
    }

    const type_id = self.program.expression(id).type_id;

    const input: Input = .{
        .mode = switch (mode) {
            .reference => .Reference,
            .value => .Value,
            .discard => .Discard,
            .consume => .Consume,
        },
        .state_active = self.state_active,
        .consumer = consumer != null,
        .projected_output = projected_output,
        .flat = layout.flat(self, type_id),
        .represented = layout.represented(self, type_id),
        .aggregate = layout.aggregate(self, type_id),
        .state_represented = self.state_plan.represented(self.program, type_id),
        .buffer_candidate = self.plan.get(id).buffered,
        .scalar_result = if (consumer) |selected| @import("../types/scalar.zig").check(self.program.types, self.program.expression(selected.result).type_id) else false,
        .pure = null,
        .local = null,
        .forwarded = null,
        .buffered = null,
        .deep = null,
        .abi = null,
        .shallow = null,
        .projection = null,
        .initial = null,
    };

    var frame: Frame = .{ .lowering = self, .iteration = iteration, .consumer = consumer, .type_id = type_id, .facts = input };
    const entry = @import("generated_execute_loop_layout");
    var memory = std.heap.FixedBufferAllocator.init(&.{});
    const action = try entry.executeIn(memory.allocator(), @ptrCast(&frame));

    return .{
        .representation = switch (action) {
            .Plain => .plain,
            .Stack => .stack,
            .State => .state,
            .Deep => .deep,
            .Buffered => .buffered,
            .Dereference => .dereference,
            .Reject => .reject,
            else => unreachable,
        },
        .forwarded = frame.forwarded,
        .pure = frame.facts.pure.?,
        .direct_initial = frame.facts.initial orelse false,
    };
}

pub fn chooseLoopLayout(handle: *const anyopaque) Action {
    const frame = Frame.borrow(handle);
    var memory = std.heap.FixedBufferAllocator.init(&.{});
    const action = model.executeIn(memory.allocator(), &frame.facts) catch unreachable;

    return zx.columns.view(Action, action);
}

pub fn checkLoopLayout(handle: *const anyopaque, action: Action) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const iteration = frame.iteration;

    switch (action) {
        .CheckPure => frame.facts.pure = try layout.eligible(self.allocator, self.program, iteration, self.pure_functions),
        .CheckLocal => frame.facts.local = try layout.eligible(self.allocator, self.program, iteration, self.local_functions),
        .CheckForwarding => {
            frame.forwarded = try layout.forwarded(self, iteration);
            frame.facts.forwarded = frame.forwarded != null;
        },
        .CheckBuffers => frame.facts.buffered = try layout.buffers(self.allocator, self.program, iteration, self.identity_free_functions, self.plan.flags),
        .CheckDeep => frame.facts.deep = try layout.deep(self.allocator, self.program, iteration, self.identity_free_functions),
        .CheckAbi => frame.facts.abi = try layout.abi(self, iteration, frame.type_id),
        .CheckShallow => frame.facts.shallow = try layout.shallow(self.allocator, self.program, iteration),
        .CheckProjection => {
            const selected = frame.consumer.?;

            frame.facts.projection = consumers.projection(self.program, selected.result, selected.symbol);
        },
        .CheckInitial => frame.facts.initial = try layout.initialValue(self.allocator, self.program, iteration.initial, self.identity_free_functions),
        else => unreachable,
    }
}
