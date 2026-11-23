const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");

pub const Emit = checks.attributeSchema(schema.element("Emit", struct { event: []const u8, value: []const u8 }, schema.empty), .Common);
