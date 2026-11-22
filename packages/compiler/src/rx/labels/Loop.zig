const dsl = @import("dsl");
const checks = @import("../checks.zig");
const Call = @import("Call.zig").Call;

pub const Loop = checks.attributeSchema(
    dsl.element("Loop", struct { on: []const u8 }, dsl.sequence(.{Call})),
    .Common,
);
