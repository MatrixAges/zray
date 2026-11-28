const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const generated = @import("genz_options").generated_analysis;
const Statements = if (generated) @import("../../node/blocks.zig").Sequence else std.ArrayList(node.Statement);

pub const Mode = enum { value, value_layout, row_value, pointer, layout, row_layout, borrow, view_value, view_layout };

pub fn convertStateValue(frame: *anyopaque, body: *anyopaque, type_id: u32, value_id: u32, mode: @import("execution_abi").layouts.@"zig:ast_rows".StateValueMode, bind: bool) Lower.Error!u32 {
    const self = @import("../expressions/evaluate.zig").borrow(frame);
    const sequence: *Statements = @ptrCast(@alignCast(body));
    const expression: node.ExpressionId = @fromBackingInt(value_id);
    const target: ir.TypeId = @fromBackingInt(type_id);

    if (mode == .Construct) return @backingInt(try self.construct(target, expression));

    if (mode == .IterationInput or mode == .IterationOutput) {
        const context = self.iteration_resources.?.context;

        return @backingInt(try @import("../iteration_value/conversion.zig").convert(context, target, expression, mode == .IterationOutput));
    }

    const source = if (bind) try aggregate.bind(self, sequence, expression) else expression;

    const conversion_mode: Mode = switch (mode) {
        .Borrow => .borrow,
        .Value => .value,
        .ValueLayout => .value_layout,
        .Layout => .layout,
        .Pointer => .pointer,
        .Construct, .IterationInput, .IterationOutput => unreachable,
        .ViewLayout => .view_layout,
    };

    return @backingInt(try convert(self, sequence, target, source, conversion_mode));
}

pub fn convert(self: *Lower, body: anytype, id: ir.TypeId, value: node.ExpressionId, mode: Mode) Lower.Error!node.ExpressionId {
    if (!generated) return @import("conversion_seed.zig").convert(self, body, id, value, mode);
    if (!self.state_plan.represented(self.program, id)) return value;

    return @import("conversion_emission.zig").lower(self, body, id, value, mode);
}

pub fn read(self: *Lower, id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    var body: Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;

    defer if (generated) body.deinit();

    const source = try aggregate.bind(self, &body, value);
    const converted = try convert(self, &body, id, source, .value);

    return aggregate.finish(self, &body, converted);
}
