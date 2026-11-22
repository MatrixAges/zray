const dsl = @import("dsl");
const checks = @import("../checks.zig");

const Base = dsl.element("Call", struct {
    @"fn": ?[]const u8 = null,
    module: ?[]const u8 = null,
    in: ?[]const u8 = null,
    setter: ?[]const u8 = null,
}, dsl.empty);

pub const Call = checks.attributeSchema(Base, .Call);
