const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");

pub const Args = checks.attributeSchema(schema.element("Args", struct {
    in: []const u8,
    out: []const u8,
}, schema.empty), .Common);
