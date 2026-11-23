const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const steps = @import("../steps.zig");
pub const Case = checks.attributeSchema(schema.element("Case", struct { value: []const u8 }, steps.children(.Body)), .Common);
