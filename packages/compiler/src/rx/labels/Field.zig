const dsl = @import("dsl");
const checks = @import("../checks.zig");

const FieldBase = dsl.element("Field", struct {
    name: []const u8,
    type: []const u8,
}, dsl.empty);

pub const Field = checks.attributeSchema(FieldBase, .Field);
