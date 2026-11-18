const std = @import("std");
const zx = @import("zx");
const rx = @import("rx");
const Self = @This();

argument: ?*const rx.ast.Attribute = null,
function: ?*const rx.ast.Attribute = null,
member: ?*const rx.ast.Attribute = null,
module: ?*const rx.ast.Attribute = null,
setter: ?*const rx.ast.Attribute = null,
pub fn scan(node: rx.ast.Node) Self {
    if (!@import("rx_options").generated_graph) return seed(node.attributes);
    if (node.attributes.len == 0) return .{};

    const rule = @import("generated_rx_call_attributes");
    const Input = std.meta.Child(rule.Input);
    const attributes = node.attributes;
    const names = @import("zx").memory.borrowTextColumn("name", attributes);
    const input: Input = .{ .names = @ptrCast(&names), .count = attributes.len };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const slots = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return .{
        .argument = at(attributes, slots.argument),
        .function = at(attributes, slots.function),
        .member = at(attributes, slots.member),
        .module = at(attributes, slots.module),
        .setter = at(attributes, slots.setter),
    };
}

fn at(attributes: []const rx.ast.Attribute, index: ?u64) ?*const rx.ast.Attribute {
    return if (index) |row| &attributes[@intCast(row)] else null;
}

fn seed(attributes: []const rx.ast.Attribute) Self {
    var found: Self = .{};

    for (attributes) |*attribute| {
        if (std.mem.eql(u8, attribute.name, "in")) {
            found.argument = found.argument orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "fn")) {
            found.function = found.function orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "export")) {
            found.member = found.member orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "module")) {
            found.module = found.module orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "setter")) {
            found.setter = found.setter orelse attribute;
        }
    }

    return found;
}
