const std = @import("std");
const ast = @import("dsl").ast;
const zx = @import("zx");
const memory = zx.memory;
const Kind = @FieldType(ast.Attribute, "kind");
const Self = @This();

names: memory.TextColumn,
values: memory.TextColumn,
kinds: memory.ReadColumn,
comptime {
    std.debug.assert(@sizeOf(Kind) == @sizeOf(bool));
    std.debug.assert(@backingInt(Kind.string) == 0 and @backingInt(Kind.expression) == 1);
}

pub fn supports(comptime Node: type) bool {
    return Node == ast.View or @hasDecl(Node, "schemaRows");
}

pub inline fn bind(node: anytype) Self {
    if (comptime @TypeOf(node) != ast.View) return undefined;

    const attributes = node.node.attributes;

    return .{
        .names = memory.borrowTextColumn("name", attributes),
        .values = memory.borrowTextColumn("value", attributes),
        .kinds = memory.borrowReadColumn(Kind, "kind", attributes),
    };
}

pub inline fn wire(self: *const Self, comptime Rows: type, node: anytype) Rows {
    if (comptime @TypeOf(node) == ast.View) return .{
        .names = @ptrCast(&self.names),
        .values = @ptrCast(&self.values),
        .kinds = @ptrCast(&self.kinds),
        .source = "",
        .decoded = "",
        .indexed = &.{},
        .count = node.node.attributes.len,
    };

    const indexed = node.schemaRows();

    return .{
        .names = null,
        .values = null,
        .kinds = null,
        .source = indexed.source,
        .decoded = indexed.decoded,
        .indexed = zx.columns.slice(@FieldType(Rows, "indexed"), indexed.rows),
        .count = indexed.rows.len,
    };
}
