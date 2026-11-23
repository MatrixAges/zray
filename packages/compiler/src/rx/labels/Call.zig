const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");

const Base = schema.element("Call", struct {
    @"fn": ?[]const u8 = null,
    module: ?[]const u8 = null,
    in: ?[]const u8 = null,
    setter: ?[]const u8 = null,
}, schema.empty);

pub const Call = checks.attributeSchema(Base, .Call);
