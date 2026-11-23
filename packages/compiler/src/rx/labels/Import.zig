const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const ImportBase = schema.element("Import", struct { from: []const u8 }, schema.empty);
pub const Import = checks.attributeSchema(ImportBase, .Import);
