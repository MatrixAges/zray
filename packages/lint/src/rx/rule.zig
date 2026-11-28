const std = @import("std");
const generated = @import("generated");
const Input = std.meta.Child(generated.Input);
pub const Mode = @FieldType(Input, "mode");
const NodeItem = std.meta.Child(std.meta.Child(@FieldType(Input, "nodes")));
const AttributeItem = std.meta.Child(std.meta.Child(@FieldType(Input, "attributes")));

pub fn run(allocator: std.mem.Allocator, mode: Mode, source: []const u8, width: usize, node: anytype) std.mem.Allocator.Error![]u8 {
    const Entry = struct { view: @TypeOf(node), slot: *NodeItem };
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    var nodes: std.ArrayList(*const NodeItem) = .empty;
    var attributes: std.ArrayList(*const AttributeItem) = .empty;
    var queue: std.ArrayList(Entry) = .empty;
    const root_slot = try temporary.create(NodeItem);

    try nodes.append(temporary, root_slot);
    try queue.append(temporary, .{ .view = node, .slot = root_slot });

    var queue_index: usize = 0;

    while (queue_index < queue.items.len) : (queue_index += 1) {
        const current = queue.items[queue_index];
        const location = current.view.location();
        const attr_start = attributes.items.len;
        const attr_count = current.view.attributeCount();

        for (0..attr_count) |index| {
            const attribute = current.view.attribute(index);
            const slot = try temporary.create(AttributeItem);

            slot.* = .{
                .name = attribute.name,
                .offset = attribute.offset,
                .value_offset = attribute.value_offset,
                .raw_len = if (attribute.raw) |raw| raw.len else 0,
            };

            try attributes.append(temporary, slot);
        }

        const child_start = nodes.items.len;
        var children = current.view.children();

        while (children.next()) |child| {
            const child_slot = try temporary.create(NodeItem);

            try nodes.append(temporary, child_slot);
            try queue.append(temporary, .{ .view = child, .slot = child_slot });
        }

        current.slot.* = .{
            .name = current.view.name(),
            .offset = location.offset,
            .column = location.column,
            .whitespace_only = current.view.whitespaceOnly(),
            .attr_start = attr_start,
            .attr_count = attr_count,
            .child_start = child_start,
            .child_count = nodes.items.len - child_start,
        };
    }

    const output = generated.executeIn(temporary, &.{
        .mode = mode,
        .source = source,
        .source_text = source,
        .width = width,
        .nodes = nodes.items,
        .attributes = attributes.items,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return allocator.dupe(u8, output);
}
