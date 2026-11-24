const std = @import("std");
const rx = @import("rx");
const Self = @This();

argument: ?*const rx.ast.Attribute = null,
function: ?*const rx.ast.Attribute = null,
module: ?*const rx.ast.Attribute = null,
setter: ?*const rx.ast.Attribute = null,
pub fn seed(attributes: []const rx.ast.Attribute) Self {
    var found: Self = .{};

    for (attributes) |*attribute| {
        if (std.mem.eql(u8, attribute.name, "in")) {
            found.argument = found.argument orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "fn")) {
            found.function = found.function orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "module")) {
            found.module = found.module orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "setter")) {
            found.setter = found.setter orelse attribute;
        }
    }

    return found;
}
