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
const Types = if (generated) std.meta.Child(@FieldType(Input, "types")) else void;

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

    const types = ir.TypeTable.borrow(Types, self.program.types);
    const expressions: *const ir.ExpressionTable = &self.program.expressions;

    const input: Input = .{
        .types = &types,
        .expressions = zx.columns.pointer(@FieldType(Input, "expressions"), expressions),
        .function_inputs = zx.columns.slice(@FieldType(Input, "function_inputs"), self.program.functions.input_types),
        .function_outputs = zx.columns.slice(@FieldType(Input, "function_outputs"), self.program.functions.output_types),
        .pure_functions = self.pure_functions,
        .local_functions = self.local_functions,
        .value_functions = self.value_functions,
        .identity_free_functions = self.identity_free_functions,
        .flags = std.mem.sliceAsBytes(self.plan.flags),
        .condition = @backingInt(iteration.condition),
        .body = @backingInt(iteration.body),
        .initial = @backingInt(iteration.initial),
        .parameter = @backingInt(iteration.parameter),
        .condition_parameter = @backingInt(iteration.condition_parameter),
        .type_id = @backingInt(type_id),
        .state_type = @backingInt(self.program.expression(iteration.initial).type_id),
        .symbol_count = self.program.symbols.count(),
        .facts = &facts,
        .postcondition = iteration.postcondition,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

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
