const dsl = @import("dsl");
const checks = @import("../checks.zig");

pub const Args = checks.attributeSchema(dsl.element("Args", struct {
    in: []const u8,
    out: []const u8,
}, dsl.empty), .Common);
