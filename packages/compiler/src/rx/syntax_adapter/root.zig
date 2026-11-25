const std = @import("std");
const dsl = @import("dsl");
const zx = @import("zx");
const ast = dsl.ast;
pub const values = @import("value.zig");
pub const references = @import("references.zig");

const Document = struct { node: dsl.ast.Node, references: ?*const references.Index = null };

pub fn location(input: anytype) dsl.ast.Location {
    return .{ .offset = @intCast(input.offset), .line = @intCast(input.line), .column = @intCast(input.column) };
}

const coordinates = .{
    .offset = &.{ "location", "offset" },
    .line = &.{ "location", "line" },
    .column = &.{ "location", "column" },
};

comptime {
    const Kind = @FieldType(ast.Attribute, "kind");

    std.debug.assert(@sizeOf(Kind) == 1 and @backingInt(Kind.string) == 0 and @backingInt(Kind.expression) == 1);
}

pub fn convert(comptime rules: anytype, allocator: std.mem.Allocator, temporary: std.mem.Allocator, source: []const u8, input: anytype) !Document {
    const tree = input.tree;
    const slots = try temporary.alloc(u64, tree.nodes.len + tree.text.len);
    var node_slots = slots[0..tree.nodes.len];
    var text_slots = slots[tree.nodes.len..];
    const decoded = try values.materialize(rules.decode, allocator, source, tree.parts, input.control.decoded_length);
    const nodes = try allocator.alloc(ast.Node, tree.nodes.len);
    const attributes = try allocator.alloc(ast.Attribute, tree.attributes.len);
    const text = try allocator.alloc(ast.Text, tree.text.len);
    const Parameter = @typeInfo(@TypeOf(rules.publish)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const memory = zx.memory;
    var node_output: memory.RowOutput(ast.Node, std.meta.Child(@FieldType(Input, "nodes")), coordinates) = undefined;
    var text_output: memory.RowOutput(ast.Text, std.meta.Child(@FieldType(Input, "text")), coordinates) = undefined;

    var attribute_output: memory.RowOutput(ast.Attribute, std.meta.Child(@FieldType(Input, "attributes")), .{
        .offset = coordinates.offset,
        .line = coordinates.line,
        .column = coordinates.column,
        .value_offset = &.{ "value_location", "offset" },
        .value_line = &.{ "value_location", "line" },
        .value_column = &.{ "value_location", "column" },
    }) = undefined;

    node_output.init();
    text_output.init();
    attribute_output.init();
    node_output.bind(nodes);
    text_output.bind(text);
    attribute_output.bind(attributes);

    const indexed = @TypeOf(rules.scan) != @TypeOf(null);

    const publication: Input = .{
        .source = source,
        .decoded = decoded,
        .tree = tree,
        .root = input.control.result,
        .node_slots = @ptrCast(&node_slots),
        .text_slots = @ptrCast(&text_slots),
        .indexed = indexed,
        .nodes = &node_output.view,
        .attributes = &attribute_output.view,
        .text = &text_output.view,
        .storage = &.{
            .nodes = &.{ .bytes = std.mem.sliceAsBytes(nodes), .width = @sizeOf(ast.Node) },
            .attributes = &.{ .bytes = std.mem.sliceAsBytes(attributes), .width = @sizeOf(ast.Attribute) },
            .text = &.{ .bytes = std.mem.sliceAsBytes(text), .width = @sizeOf(ast.Text) },
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const extent = zx.columns.invoke(rules.publish, empty.allocator(), &publication) catch unreachable;

    return .{
        .node = nodes[0],
        .references = if (comptime indexed) try references.build(rules.scan, rules.references, allocator, temporary, source, input, node_slots, nodes, attributes, @intCast(extent)) else null,
    };
}
