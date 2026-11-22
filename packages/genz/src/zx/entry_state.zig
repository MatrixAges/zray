const node = @import("../node.zig");
const Lower = @import("lower.zig");
const types = @import("types.zig");
const aggregate = @import("aggregate.zig");
const conversion = @import("state_value/conversion.zig");
const emit = @import("entry/emitting.zig");

pub fn declarations(self: *Lower, output: *@import("../node/declarations.zig").Output, name: []const u8) Lower.Error!bool {
    if (!emit.generated) return @import("entry/state_seed.zig").declarations(self, output);

    if (@import("entry/policy.zig").forwarded(self)) |function| {
        try emit.alias(self, output, true, try self.requestFunction(function, .value));

        return false;
    }

    var state = try self.functionValue(name);

    state.function.exported = true;

    try output.append(self.allocator, state);
    try view(self, output, state.function);

    return true;
}

fn view(self: *Lower, output: *@import("../node/declarations.zig").Sequence, state: node.Function) Lower.Error!void {
    const saved = try @import("state_value/root.zig").enter(self);

    defer if (saved) |scope| scope.restore();

    @import("functions/context.zig").reset(self, .StateView);

    const input_type = try types.get(self, self.view_types, self.program.input_type);
    const prepared = try emit.prepare(self, state.parameters, input_type);
    const arguments = prepared.arguments;
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    arguments[1] = try conversion.convert(self, &body, self.program.input_type, arguments[1], .view_value);

    const result = try aggregate.bind(self, &body, try emit.call(self, state.name, arguments));
    const returned = try conversion.convert(self, &body, self.program.output_type, result, .view_layout);
    const output_type = try types.get(self, self.view_types, self.program.output_type);
    const references = try self.referenceBlock();
    const values = try body.block(self.allocator);

    const statements = try @import("../node/blocks.zig").tail(
        self.allocator,
        self.builder.nodes,
        &.{ references.start, values.start },
        &.{ references.len, values.len },
    );

    try emit.finish(self, output, .{
        .state = state,
        .value = returned,
        .output_type = output_type,
        .parameters = prepared.parameters,
        .body = statements,
    });
}
