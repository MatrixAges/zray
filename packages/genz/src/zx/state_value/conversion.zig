const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const generated = @import("genz_options").generated_analysis;
const Statements = if (generated) @import("../../node/blocks.zig").Sequence else std.ArrayList(node.Statement);

pub const Mode = enum { value, value_layout, row_value, pointer, layout, row_layout, borrow, view_value, view_layout };

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
