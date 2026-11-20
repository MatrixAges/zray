const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");

pub fn lower(self: *Lower, values: ir.Block) Lower.Error!node.Block {
    if (values.len == 0) return .{};
    if (!@import("genz_options").generated_analysis) return @import("statements/seed.zig").lower(self, values);

    return @import("statements/traversal/host.zig").lower(self, values);
}

pub const writes = @import("control/writes.zig").writes;
