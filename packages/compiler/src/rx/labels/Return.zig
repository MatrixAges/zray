const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");

pub const Return = checks.attributeSchema(schema.element("Return", struct { value: []const u8 }, schema.empty), .Common);
