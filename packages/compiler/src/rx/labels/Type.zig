const dsl = @import("dsl");
const checks = @import("../checks.zig");
const Base = dsl.element("Type", struct { from: []const u8, as: []const u8 }, dsl.empty);
pub const Type = checks.attributeSchema(Base, .Type);
