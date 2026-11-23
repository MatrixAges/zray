const schema = @import("../schema.zig").builders;
const steps = @import("../steps.zig");
pub const Parallel = schema.element("Parallel", struct {}, steps.children(.Parallel));
