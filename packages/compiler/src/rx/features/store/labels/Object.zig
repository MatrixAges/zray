const std = @import("std");
const dsl = @import("dsl");
const schema = @import("../../../schema.zig").builders;
const checks = @import("../../../checks.zig");
const Field = @import("Field.zig").Field;
const ObjectBase = schema.element("Object", struct { name: []const u8 }, schema.list(Field, .{ .min = 1 }));
pub const Object = dsl.refineAlloc(ObjectBase, checkObject);

fn checkObject(allocator: std.mem.Allocator, data: ObjectBase.Data, node: anytype, _: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const view = dsl.ast.view(node);
    const adapter = @import("../schema/adapter.zig");

    try checks.validate(.Common, data.attributes, view, reporter);
    if (comptime @import("rx_options").generated_rules and adapter.supports(@TypeOf(view))) return adapter.uniqueFields(allocator, view, reporter);
    try checks.uniqueChildren(node, "Field", "name", reporter);
}
