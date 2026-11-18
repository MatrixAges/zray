const dsl = @import("dsl");
const checks = @import("../checks.zig");

pub const Return = checks.attributeSchema(dsl.element("Return", struct { value: []const u8 }, dsl.empty), .Common);
