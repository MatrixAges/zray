const schema = @import("../../../schema.zig").builders;
const checks = @import("../../../checks.zig");

pub const StoreReference = checks.attributeSchema(schema.element("Store", struct {
    from: []const u8,
    as: ?[]const u8 = null,
}, schema.empty), .Common);
