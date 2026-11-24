const std = @import("std");
const ast = @import("dsl").ast;

pub fn bind(comptime Layout: type) Layout {
    const Kind = @FieldType(ast.Attribute, "kind");
    const words = @typeInfo(ast.Location).@"struct".field_types;

    comptime {
        std.debug.assert(@sizeOf(Kind) == 1);
        std.debug.assert(@backingInt(Kind.string) == 0 and @backingInt(Kind.expression) == 1);

        for (words) |Word| std.debug.assert(Word == usize);

        std.debug.assert(@sizeOf(ast.Location) == words.len * @sizeOf(usize));
    }

    return .{
        .node_width = @sizeOf(ast.Node),
        .node_name = @offsetOf(ast.Node, "name"),
        .node_location = @offsetOf(ast.Node, "location"),
        .node_children = @offsetOf(ast.Node, "children"),
        .node_attributes = @offsetOf(ast.Node, "attributes"),
        .node_text = @offsetOf(ast.Node, "text"),
        .attribute_width = @sizeOf(ast.Attribute),
        .attribute_name = @offsetOf(ast.Attribute, "name"),
        .attribute_value = @offsetOf(ast.Attribute, "value"),
        .attribute_kind = @offsetOf(ast.Attribute, "kind"),
        .attribute_location = @offsetOf(ast.Attribute, "location"),
        .attribute_value_location = @offsetOf(ast.Attribute, "value_location"),
        .attribute_raw_value = @offsetOf(ast.Attribute, "raw_value"),
        .text_width = @sizeOf(ast.Text),
        .text_value = @offsetOf(ast.Text, "value"),
        .text_location = @offsetOf(ast.Text, "location"),
        .location_width = @sizeOf(ast.Location),
    };
}
