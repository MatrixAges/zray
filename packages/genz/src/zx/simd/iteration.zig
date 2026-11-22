const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Consumer = @import("../iteration_consumer.zig").Consumer;

pub fn lower(self: *Lower, id: ir.ExprId, consumer: Consumer) Lower.Error!?node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("seed/iteration.zig").lower(self, self.program.expression(id).value.iteration, consumer);

    return @import("emission.zig").lower(self, id, consumer);
}
