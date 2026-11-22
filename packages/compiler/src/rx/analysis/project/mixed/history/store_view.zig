const std = @import("std");
const ast = @import("dsl").ast;
const Module = @import("rx").ModuleSource;

pub inline fn historyStoreNode(source: *const anyopaque, index: u64, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    const stores: *const []const Module = @ptrCast(@alignCast(source));

    return @ptrCast(&stores.*[@intCast(index)].node);
}

pub inline fn historyXmlNodesShare(left: *const anyopaque, right: *const anyopaque) bool {
    return left == right;
}

pub inline fn historyNodeName(handle: *const anyopaque) []const u8 {
    return borrow(ast.Node, handle).name;
}

pub inline fn historyNodePosition(handle: *const anyopaque) []const u8 {
    return words(&borrow(ast.Node, handle).location);
}

pub inline fn historyNodeRows(handle: *const anyopaque, part: anytype, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    const node = borrow(ast.Node, handle);

    return switch (part) {
        .Attributes => @ptrCast(&node.attributes),
        .Children => @ptrCast(&node.children),
        .Text => @ptrCast(&node.text),
    };
}

pub inline fn historyNodeAt(rows: *const anyopaque, index: u64, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(at(ast.Node, rows, index));
}

pub inline fn historyAttributeAt(rows: *const anyopaque, index: u64, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(at(ast.Attribute, rows, index));
}

pub inline fn historyTextAt(rows: *const anyopaque, index: u64, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(at(ast.Text, rows, index));
}

pub inline fn historyXmlRowCount(rows: *const anyopaque) u64 {
    return borrow([]const u8, rows).len;
}

pub inline fn historyXmlRowsShare(left: *const anyopaque, right: *const anyopaque) bool {
    return borrow([]const u8, left).ptr == borrow([]const u8, right).ptr;
}

pub inline fn historyAttributeIsExpression(handle: *const anyopaque) bool {
    return borrow(ast.Attribute, handle).kind == .expression;
}

pub inline fn historyAttributeName(handle: *const anyopaque) []const u8 {
    return borrow(ast.Attribute, handle).name;
}

pub inline fn historyAttributeValue(handle: *const anyopaque) []const u8 {
    return borrow(ast.Attribute, handle).value;
}

pub inline fn historyAttributeRaw(handle: *const anyopaque) ?[]const u8 {
    return borrow(ast.Attribute, handle).raw_value;
}

pub inline fn historyAttributePosition(handle: *const anyopaque, value: bool) []const u8 {
    const attribute = borrow(ast.Attribute, handle);

    return words(if (value) &attribute.value_location else &attribute.location);
}

pub inline fn historyTextValue(handle: *const anyopaque) []const u8 {
    return borrow(ast.Text, handle).value;
}

pub inline fn historyTextPosition(handle: *const anyopaque) []const u8 {
    return words(&borrow(ast.Text, handle).location);
}

inline fn borrow(comptime T: type, pointer: *const anyopaque) *const T {
    return @ptrCast(@alignCast(pointer));
}

inline fn at(comptime T: type, rows: *const anyopaque, index: u64) *const T {
    return &borrow([]const T, rows).*[@intCast(index)];
}

inline fn words(position: *const ast.Location) []const u8 {
    comptime {
        const components = @typeInfo(ast.Location).@"struct".field_types;

        for (components) |Component| {
            if (Component != usize) @compileError("XML positions must contain native words");
        }

        if (@sizeOf(ast.Location) != components.len * @sizeOf(usize)) @compileError("XML position words must not contain padding");
    }

    return std.mem.asBytes(position);
}
