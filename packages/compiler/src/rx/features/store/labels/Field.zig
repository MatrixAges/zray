const schema = @import("../../../schema.zig").builders;
const checks = @import("../../../checks.zig");

const FieldBase = schema.element("Field", struct {
    name: []const u8,
    type: []const u8,
    value: []const u8,
}, schema.empty);

pub const Field = checks.attributeSchema(FieldBase, .StoreField);
