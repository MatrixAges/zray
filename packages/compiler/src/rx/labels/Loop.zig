const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const Call = @import("Call.zig").Call;

pub const Loop = checks.attributeSchema(
    schema.element("Loop", struct { on: []const u8 }, schema.sequence(.{Call})),
    .Common,
);
