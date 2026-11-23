const schema = @import("../schema.zig").builders;
const steps = @import("../steps.zig");
pub const Default = schema.element("Default", struct {}, steps.children(.Body));
