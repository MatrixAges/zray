const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub fn lower(self: *Lower, id: ir.ExprId, value: ir.Transform) Lower.Error!?node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("seed/root.zig").lower(self, id, value);

    return @import("emission.zig").lower(self, id, null);
}
