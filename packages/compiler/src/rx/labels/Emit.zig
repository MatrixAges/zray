const dsl = @import("dsl");
const checks = @import("../checks.zig");

pub const Emit = checks.attributeSchema(dsl.element("Emit", struct { event: []const u8, value: []const u8 }, dsl.empty), .Common);
