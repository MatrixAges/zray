const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const steps = @import("../steps.zig");
pub const Task = checks.attributeSchema(schema.element("Task", struct { name: []const u8, out: ?[]const u8 = null }, steps.children(.Task)), .Common);
pub const Sequential = Task;
