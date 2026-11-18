const std = @import("std");
const kinds = @import("../../attribute_kind.zig");
const paths = @import("../../paths.zig");
const adapter = @import("adapter.zig");

pub fn inspect(comptime policy: adapter.Policy, attributes: anytype, node: anytype) adapter.Finding {
    var finding: adapter.Finding = .{ .issue = .None };

    for (0..node.attributeCount()) |index| {
        const item = node.schemaAttribute(index);
        const role = kinds.role(node.name(), item.name);
        const braced = role == .Expression or role == .Type;

        if (role != .Value and (item.kind == .expression) != braced) {
            return .{ .issue = if (braced) .Expression else .Static, .index = index };
        }

        if (policy == .StoreField and std.mem.eql(u8, item.name, "value")) continue;
        if (item.kind == .string and role == .Value) continue;
        if (finding.issue != .None and (policy != .StoreField or !std.mem.eql(u8, item.name, "name"))) continue;

        if (std.mem.trim(u8, item.value, " \t\r\n").len == 0) {
            finding = .{ .issue = if (policy == .StoreField) .EmptyField else .Empty, .index = index };
        }
    }

    if (finding.issue != .None) return finding;

    switch (policy) {
        .Common, .StoreField => {},
        .Module => if (attributes.@"fn") |reference| {
            if (node.childCount() != 0) return .{ .issue = .ModuleChildren };
            if (!paths.isFunctionReference(reference)) return .{ .issue = .ModuleFunction };
        },
        .Call => {
            if ((attributes.@"fn" == null) == (attributes.module == null)) return .{ .issue = .CallTarget };

            if (attributes.module) |reference| {
                if (attributes.setter != null) return .{ .issue = .CallSetter };
                if (!paths.isModuleReference(reference)) return .{ .issue = .CallModule };
            }
        },
        .Import => if (!paths.isModuleReference(attributes.from)) return .{ .issue = .ImportModule },
        .Route => if (!paths.isModuleReference(attributes.service)) return .{ .issue = .RouteService },
        .Type => {
            if (!paths.isFunctionReference(attributes.from)) return .{ .issue = .TypeSource };
            if (!identifier(attributes.as)) return .{ .issue = .TypeAlias };
        },
        .Field => if (!identifier(attributes.name)) return .{ .issue = .FieldName },
    }

    return finding;
}

fn identifier(name: []const u8) bool {
    return @import("frontend").binding_path.valid(name) and std.mem.indexOfScalar(u8, name, '.') == null;
}
