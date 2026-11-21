const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("seed.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
pub const analysis = @import("analysis.zig");
pub const functions = analysis.functions;
pub const containsDescendant = analysis.containsDescendant;

pub fn expression(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return seed.expression(self, id);

    return @import("../expressions/evaluate.zig").value(self, id);
}

pub fn invocation(self: *Lower, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.invocation(self, value);

    return invokeBlock(self, value, false);
}

pub fn pointerInvocation(self: *Lower, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.pointerInvocation(self, value);

    return invokeBlock(self, value, true);
}

pub fn borrowInvocation(self: *Lower, body: if (generated) *Sequence else *std.ArrayList(node.Statement), value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.borrowInvocation(self, body, value);

    return @import("../invocation/execute.zig").value(self, body, value, true, false);
}

fn invokeBlock(self: *Lower, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call"), pointer: bool) Lower.Error!node.ExpressionId {
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    return @import("../invocation/execute.zig").value(self, &body, value, false, pointer);
}
