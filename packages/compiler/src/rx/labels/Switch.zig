const std = @import("std");
const dsl = @import("dsl");
const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const Case = @import("Case.zig").Case;
const Default = @import("Default.zig").Default;

const SwitchBase = schema.element("Switch", struct { on: []const u8 }, schema.list(schema.choice(.{
    .case = Case,
    .default = Default,
}), .{ .min = 1 }));

pub const Switch = dsl.refineAlloc(SwitchBase, checkSwitch);

fn checkSwitch(allocator: std.mem.Allocator, data: SwitchBase.Data, input: anytype, _: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const node = dsl.ast.view(input);

    try checks.validate(.Common, data.attributes, node, reporter);

    return @import("../schema/selection/adapter.zig").checkSwitch(allocator, node, reporter);
}
