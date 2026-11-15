const std = @import("std");
const zx = @import("zx");
const rx = @import("rx");
const Self = @This();
const batch_size = 8;

argument: ?*const rx.ast.Attribute = null,
function: ?*const rx.ast.Attribute = null,
module: ?*const rx.ast.Attribute = null,
setter: ?*const rx.ast.Attribute = null,
pub fn scan(node: rx.ast.Node) Self {
    if (!@import("rx_options").generated_graph) return seed(node.attributes);

    const rule = @import("generated_rx_call_attributes");
    const Input = std.meta.Child(rule.Input);
    const Slots = std.meta.Child(@FieldType(Input, "slots"));
    const attributes = node.attributes;
    var slots: Slots = .{ .argument = null, .function = null, .module = null, .setter = null };
    var names: [batch_size][]const u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    var offset: usize = 0;

    while (offset < attributes.len) {
        const batch = attributes[offset..][0..@min(names.len, attributes.len - offset)];

        for (batch, names[0..batch.len]) |*attribute, *name| name.* = attribute.name;

        const input: Input = .{ .names = names[0..batch.len], .offset = offset, .slots = &slots };
        const selected = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

        slots = zx.columns.view(Slots, selected);
        offset += batch.len;
    }

    return .{
        .argument = at(attributes, slots.argument),
        .function = at(attributes, slots.function),
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
        } else if (std.mem.eql(u8, attribute.name, "module")) {
            found.module = found.module orelse attribute;
        } else if (std.mem.eql(u8, attribute.name, "setter")) {
            found.setter = found.setter orelse attribute;
        }
    }

    return found;
}
