const schema = @import("../../../schema.zig").builders;
const checks = @import("../../../checks.zig");
const Entry = @import("../entries.zig").Entry;
pub const Group = checks.attributeSchema(schema.element("Group", struct { prefix: []const u8 }, schema.list(Entry, .{ .min = 1 })), .Common);
