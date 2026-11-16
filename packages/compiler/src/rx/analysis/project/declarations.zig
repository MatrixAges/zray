const std = @import("std");
const rx = @import("rx");
const generated = @import("rx_options").generated_graph;
const memory = @import("zx").memory;
const rule = if (generated) @import("generated_rx_declaration_next") else void;
const Self = @This();
pub const Kind = if (generated) @FieldType(std.meta.Child(rule.Input), "kind") else enum { Arguments, TypeImport, Store, Field };

const Attributes = struct {
    first: *const rx.ast.Attribute,
    second: ?*const rx.ast.Attribute,
};

nodes: []const rx.ast.Node,
names: if (generated) memory.TextColumn else void,
kind: Kind,
start: usize = 0,
pub fn init(source: rx.ast.Node, kind: Kind) Self {
    const nodes = source.children;

    return .{
        .nodes = nodes,
        .names = if (generated) memory.borrowTextColumn("name", nodes) else {},
        .kind = kind,
    };
}

pub fn next(self: *Self) ?*const rx.ast.Node {
    if (self.start == self.nodes.len) return null;

    const row = if (comptime generated) indexed: {
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        const selected = rule.executeValue(scratch.allocator(), &.{
            .names = @ptrCast(&self.names),
            .count = self.nodes.len,
            .start = self.start,
            .kind = self.kind,
        }) catch unreachable;

        break :indexed if (selected) |index| @as(?usize, @intCast(index)) else null;
    } else seedNext(self.nodes, self.start, self.kind);

    const index = row orelse {
        self.start = self.nodes.len;

        return null;
    };

    self.start = index + 1;

    return &self.nodes[index];
}

pub fn attributes(node: *const rx.ast.Node, kind: Kind) Attributes {
    if (comptime generated) {
        const scan = @import("generated_rx_declaration_attributes");
        const names = memory.borrowTextColumn("name", node.attributes);
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        const slots = scan.executeValue(scratch.allocator(), &.{
            .names = @ptrCast(&names),
            .count = node.attributes.len,
            .kind = kind,
        }) catch unreachable;

        return .{
            .first = &node.attributes[@intCast(slots.first orelse unreachable)],
            .second = if (slots.second) |index| &node.attributes[@intCast(index)] else null,
        };
    }

    const target = @import("../call/target.zig");

    const primary = switch (kind) {
        .Arguments => "in",
        .Field => "name",
        else => "from",
    };

    const secondary = switch (kind) {
        .Arguments => "out",
        .Field => "value",
        else => "as",
    };

    const first = target.borrowAttribute(node.*, primary).?;
    var second = target.borrowAttribute(node.*, secondary);

    if (kind == .Store) {
        for (node.attributes) |*attribute| {
            if (std.mem.eql(u8, attribute.name, secondary)) second = attribute;
        }
    }

    return .{ .first = first, .second = second };
}

fn seedNext(nodes: []const rx.ast.Node, start: usize, kind: Kind) ?usize {
    const name = switch (kind) {
        .Arguments => "Args",
        .TypeImport => "Type",
        .Store => "Store",
        .Field => "Field",
    };

    for (nodes[start..], start..) |node, row| {
        if (std.mem.eql(u8, node.name, name)) return row;
    }

    return null;
}
