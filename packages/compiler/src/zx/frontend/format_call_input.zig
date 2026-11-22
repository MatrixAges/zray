const std = @import("std");
const lint = @import("lint");
const Attribute = lint.rx.NodeView.Attribute;
const whitespace = " \t\r\n";

pub const Output = struct {
    name: []const u8,
    prefix: []const u8,
    pub fn matches(self: Output, expression: []const u8) bool {
        const text = std.mem.trim(u8, expression, whitespace);

        return std.mem.startsWith(u8, text, self.prefix) and std.mem.eql(u8, text[self.prefix.len..], self.name);
    }
};

pub fn of(node: anytype) ?Output {
    if (std.mem.eql(u8, node.name(), "Loop")) {
        var children = node.children();
        const body = children.next() orelse return null;

        return call(body);
    }

    if (std.mem.eql(u8, node.name(), "Task")) {
        if (find(node, "out") == null) return null;

        const name = find(node, "name") orelse return null;

        return valid(name, "$ctx.task.");
    }

    return call(node);
}

fn call(node: anytype) ?Output {
    if (!std.mem.eql(u8, node.name(), "Call")) return null;

    const function = find(node, "fn");
    const path = function orelse find(node, "module") orelse return null;
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
    var name = path[if (slash) |index| index + 1 else 0..];

    for ([_][]const u8{ ".zx", ".rx", ".zig" }) |suffix| {
        if (!std.mem.endsWith(u8, name, suffix)) continue;

        name = name[0 .. name.len - suffix.len];

        break;
    }

    if (function != null) name = @import("../modules/module_path.zig").callMember(name) orelse name;

    return valid(name, "$ctx.");
}

fn valid(name: []const u8, prefix: []const u8) ?Output {
    if (name.len == 0) return null;
    for (name) |character| if (!(std.ascii.isAlphanumeric(character) or character == '_')) return null;

    return .{ .name = name, .prefix = prefix };
}

fn find(node: anytype, name: []const u8) ?[]const u8 {
    for (0..node.attributeCount()) |index| {
        const attribute = node.attribute(index);

        if (std.mem.eql(u8, attribute.name, name)) return attribute.raw;
    }

    return null;
}

pub fn remove(source: []const u8, attribute: Attribute) lint.spacing.Edit {
    const prefix = std.mem.trimEnd(u8, source[0..attribute.offset], whitespace);

    return .{ .span = .{ .start = prefix.len, .end = attribute.value_offset + attribute.raw.?.len + 1 }, .replacement = "" };
}
