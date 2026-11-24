const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const generated = @import("genz_options").generated_analysis;
const workflow = @import("collections/workflow.zig");
const seed = @import("collections_seed.zig");

pub fn lower(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    return lowerMode(self, id, null, false);
}

pub fn lowerValue(self: *Lower, id: ir.ExprId, layout: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lowerMode(self, id, layout, false);
}

pub fn projection(self: *Lower, target: ir.ExprId, index: usize) Lower.Error!?node.ExpressionId {
    if (index != 1 or self.cache.contains(target)) return null;
    if (self.iteration_value) |context| if (context.cache.contains(target)) return null;

    const value = self.program.expression(target);

    if (value.value != .list_operation or value.value.list_operation.kind != .splice) return null;

    return try lowerMode(self, target, null, true);
}

fn lowerMode(self: *Lower, id: ir.ExprId, layout: ?node.ExpressionId, removed_only: bool) Lower.Error!node.ExpressionId {
    if (generated) return workflow.run(self, id, layout, removed_only);

    return seed.lower(self, id, layout, removed_only);
}
