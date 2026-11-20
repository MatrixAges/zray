const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const seed = @import("seed.zig");
const aggregate = @import("../aggregate.zig");
const conversion = @import("../state_value/conversion.zig");

pub fn lower(self: *Lower, invocation: seed.Operation) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return seed.lower(self, invocation);

    const selected = @import("policy.zig").analyze(self, invocation);

    switch (selected.route) {
        .Value => return @import("../value_call/root.zig").invocation(self, invocation),
        .Pointer => return @import("../value_call/root.zig").pointerInvocation(self, invocation),
        .Regular => {},
    }

    const plan = selected.regular.?;
    const function = self.program.functions.at(@backingInt(invocation.function));
    var body: std.ArrayList(node.Statement) = .empty;
    const allocator = try self.builder.identifier("allocator");

    const argument = switch (plan.argument) {
        .ExternalTuple => tuple: {
            const value = self.program.expression(invocation.argument);
            const layout = try aggregate.tupleValue(self, value, value.value.tuple);
            const argument = try aggregate.bind(self, &body, try self.cast(try self.layoutExpr(value.type_id), layout));

            break :tuple try self.builder.expression(.{ .address_of = argument });
        },
        .ScalarBorrow => try @import("../value_call/argument.zig").borrow(self, &body, invocation.argument),
        .StateBorrow, .StatePointer => converted: {
            const argument = try aggregate.bind(self, &body, try self.expr(invocation.argument));

            break :converted try conversion.convert(self, &body, function.input_type, argument, if (plan.argument == .StateBorrow) .borrow else .pointer);
        },
        .Value => try self.expr(invocation.argument),
    };

    const store = if (plan.stores) try @import("../store.zig").adapter(self, invocation) else null;

    var result = try @import("emission.zig").lower(self, .{
        .function = invocation.function,
        .allocator = allocator,
        .value = argument,
        .store = store,
        .io = plan.io,
        .process = plan.process,
    });

    if (plan.convert_output) {
        result = try aggregate.bind(self, &body, result);
        result = try conversion.convert(self, &body, function.output_type, result, .value);
    }

    return if (body.items.len == 0) result else try aggregate.finish(self, &body, result);
}
