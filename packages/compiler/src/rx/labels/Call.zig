const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../checks.zig");
const paths = @import("../paths.zig");

const Base = dsl.element("Call", struct {
    @"fn": ?[]const u8 = null,
    @"export": ?[]const u8 = null,
    module: ?[]const u8 = null,
    in: ?[]const u8 = null,
    setter: ?[]const u8 = null,
}, dsl.empty);

pub const Call = dsl.refine(Base, check);

fn check(data: Base.Data, input: anytype, _: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const node = dsl.ast.view(input);

    try checks.nonEmpty(node, reporter);

    switch (@import("../schema/call/adapter.zig").check(&.{
        .has_function = data.attributes.@"fn" != null,
        .has_module = data.attributes.module != null,
        .has_input = data.attributes.in != null,
        .has_setter = data.attributes.setter != null,
    })) {
        .None => {},
        .Target => return checks.fail(node, "module", "Call requires exactly one of fn or module", reporter),
        .Input => return reporter.fail(.{ .code = .missing_attribute, .location = node.location(), .element = node.name(), .attribute = "in", .message = "Missing required attribute" }),
        .Setter => return checks.fail(node, "setter", "Store authorization belongs inside the called RX module", reporter),
    }

    if (data.attributes.module) |module| {
        if (!paths.isModuleReference(module)) return checks.fail(node, "module", "Module must reference a local RX path or a declared package module", reporter);
    }

    if (data.attributes.@"export") |name| {
        if (data.attributes.@"fn" == null) return checks.fail(node, "export", "export requires a Call.fn target", reporter);
        if (!identifier(name)) return checks.fail(node, "export", "export must name a publicly exported function", reporter);
    }
}

fn identifier(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |character| if (!(std.ascii.isAlphanumeric(character) or character == '_')) return false;

    return true;
}
