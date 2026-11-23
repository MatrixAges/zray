const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const Base = schema.element("Type", struct { from: []const u8, as: []const u8 }, schema.empty);
pub const Type = checks.attributeSchema(Base, .Type);
