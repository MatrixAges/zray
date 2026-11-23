const std = @import("std");
const dsl = @import("dsl");
const structure = @import("../../../schema.zig").builders;
const checks = @import("../../../checks.zig");
const Object = @import("Object.zig").Object;
const Type = @import("../../../labels/Type.zig").Type;
const schema = @import("../schema/adapter.zig");
pub const Groups = schema.Groups;

const StoreBase = structure.element("Store", struct {
    name: []const u8,
    version: u32,
}, structure.list(structure.choice(.{ .type = Type, .object = Object }), .{ .min = 1 }));

pub const Store = dsl.refineAlloc(StoreBase, checkStore);

fn checkStore(allocator: std.mem.Allocator, data: StoreBase.Data, input: anytype, context: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const node = dsl.ast.view(input);
    const generated = @import("rx_options").generated_rules;

    try checks.validate(.Common, data.attributes, node, reporter);

    if (comptime generated and schema.supports(@TypeOf(node))) {
        const groups = try schema.validate(allocator, data.children, node, reporter);

        if (comptime @TypeOf(context) == *?Groups) context.* = groups;

        return;
    }

    const seed = @import("../schema/seed.zig");

    try seed.check(data.children, node, reporter);

    if (comptime generated and @TypeOf(context) == *?Groups) context.* = try seed.group(allocator, node);
}
