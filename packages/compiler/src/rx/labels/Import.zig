const dsl = @import("dsl");
const checks = @import("../checks.zig");
const ImportBase = dsl.element("Import", struct { from: []const u8 }, dsl.empty);
pub const Import = checks.attributeSchema(ImportBase, .Import);
