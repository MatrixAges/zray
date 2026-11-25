const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const layout = @import("../iteration_layout.zig");
const consumers = @import("../iteration_consumer.zig");
const initial = @import("../iteration/initial.zig");
const failure = @import("../construction/publication.zig").failure;
const generated = @import("genz_options").generated_analysis;
const Mode = @import("../iteration/result.zig").Mode;
pub const Representation = enum { plain, stack, state, deep, buffered, dereference, reject };

pub const Selection = if (generated) struct {
    representation: Representation,
    forwarded: ?ir.ExprId,
    plan: initial.Plan,
} else struct {
    representation: Representation,
    forwarded: ?ir.ExprId = null,
    pure: bool = false,
    direct_initial: bool = false,
};

const entry = if (generated) @import("generated_execute_loop_layout") else void;
const Input = if (generated) std.meta.Child(entry.Input) else void;
const Facts = if (generated) std.meta.Child(@FieldType(Input, "facts")) else void;

const Frame = struct {
    lowering: *const Lower,
    iteration: ir.Iteration,
    consumer: ?consumers.Consumer,
    type_id: ir.TypeId,
    fn borrow(handle: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn choose(self: *Lower, id: ir.ExprId, iteration: ir.Iteration, mode: Mode, consumer: ?consumers.Consumer, projected_output: bool) Lower.Error!Selection {
    if (comptime !generated) {
        return @import("select_seed.zig").choose(self, id, iteration, mode, consumer, projected_output);
    }

    const type_id = self.program.expression(id).type_id;

    const facts: Facts = .{
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
        .projection = if (consumer) |selected| consumers.projection(self.program, selected.result, selected.symbol) else false,
        .initial = null,
    };

    const frame: Frame = .{ .lowering = self, .iteration = iteration, .consumer = consumer, .type_id = type_id };
    const input: Input = .{ .frame = @ptrCast(&frame), .facts = &facts, .postcondition = iteration.postcondition };
    var memory = std.heap.FixedBufferAllocator.init(&.{});
    const decision = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| return failure(err);

    return .{
        .representation = switch (decision.action) {
            .Plain => .plain,
            .Stack => .stack,
            .State => .state,
            .Deep => .deep,
            .Buffered => .buffered,
            .Dereference => .dereference,
            .Reject => .reject,
            else => unreachable,
        },
        .forwarded = if (decision.forwarded) |forwarded| @fromBackingInt(forwarded) else null,
        .plan = zx.columns.view(initial.Plan, decision),
    };
}

pub fn loopPure(handle: *const anyopaque) Lower.Error!bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return layout.eligible(self.allocator, self.program, frame.iteration, self.pure_functions);
}

pub fn loopLocalCalls(handle: *const anyopaque) Lower.Error!bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return layout.eligible(self.allocator, self.program, frame.iteration, self.local_functions);
}

pub fn loopForwardedValue(handle: *const anyopaque) Lower.Error!?u32 {
    const frame = Frame.borrow(handle);
    const forwarded = try layout.forwarded(frame.lowering, frame.iteration);

    return if (forwarded) |id| @backingInt(id) else null;
}

pub fn loopBufferLayout(handle: *const anyopaque) Lower.Error!bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return layout.buffers(self.allocator, self.program, frame.iteration, self.identity_free_functions, self.plan.flags);
}

pub fn loopDeepLayout(handle: *const anyopaque) Lower.Error!bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return layout.deep(self.allocator, self.program, frame.iteration, self.identity_free_functions);
}

pub fn loopAbiLayout(handle: *const anyopaque) Lower.Error!bool {
    const frame = Frame.borrow(handle);

    return layout.abi(frame.lowering, frame.iteration, frame.type_id);
}

pub fn loopShallowLayout(handle: *const anyopaque) Lower.Error!bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return layout.shallow(self.allocator, self.program, frame.iteration);
}

pub fn loopDirectInitial(handle: *const anyopaque) Lower.Error!bool {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return layout.initialValue(self.allocator, self.program, frame.iteration.initial, self.identity_free_functions);
}
