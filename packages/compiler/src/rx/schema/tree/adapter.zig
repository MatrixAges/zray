const std = @import("std");
const ast = @import("dsl").ast;
const zx = @import("zx");

pub fn supports(comptime Node: type) bool {
    return Node == ast.View or @hasDecl(Node, "schemaChildren");
}

fn layout(comptime Layout: type) Layout {
    const Attribute = ast.Attribute;
    const Kind = @FieldType(Attribute, "kind");

    comptime {
        std.debug.assert(@sizeOf(Kind) == 1);
        std.debug.assert(@backingInt(Kind.string) == 0 and @backingInt(Kind.expression) == 1);
    }

    return .{
        .node_width = @sizeOf(ast.Node),
        .node_name = @offsetOf(ast.Node, "name"),
        .node_children = @offsetOf(ast.Node, "children"),
        .node_attributes = @offsetOf(ast.Node, "attributes"),
        .attribute_width = @sizeOf(Attribute),
        .attribute_name = @offsetOf(Attribute, "name"),
        .attribute_value = @offsetOf(Attribute, "value"),
        .attribute_kind = @offsetOf(Attribute, "kind"),
    };
}

pub fn invoke(comptime Rule: type, allocator: std.mem.Allocator, node: anytype, input: *std.meta.Child(Rule.Input)) std.mem.Allocator.Error!Result(Rule) {
    const Input = std.meta.Child(Rule.Input);
    const Tree = std.meta.Child(@FieldType(Input, "tree"));
    const raw = @TypeOf(node) == ast.View;
    const view = if (comptime raw) {} else node.schemaChildren();

    const tree: Tree = if (comptime raw) .{
        .layout = &comptime layout(std.meta.Child(@typeInfo(@FieldType(Tree, "layout")).optional.child)),
        .source = "",
        .decoded = "",
        .nodes = &.{},
        .attributes = &.{},
        .first = &.{},
        .next = &.{},
    } else .{
        .layout = null,
        .source = view.source,
        .decoded = view.decoded,
        .nodes = zx.columns.slice(@FieldType(Tree, "nodes"), view.nodes),
        .attributes = zx.columns.slice(@FieldType(Tree, "attributes"), view.attributes),
        .first = view.first,
        .next = view.next,
    };

    input.tree = &tree;

    input.first = &.{
        .rows = if (comptime raw) std.mem.sliceAsBytes(node.node.children) else &.{},
        .head = if (comptime raw) 0 else view.head,
    };

    input.count = node.childCount();

    const request: *const Input = input;

    return zx.columns.invoke(Rule.executeValue, allocator, request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn run(comptime Rule: type, allocator: std.mem.Allocator, node: anytype) std.mem.Allocator.Error!?Finding(Rule) {
    const Input = std.meta.Child(Rule.Input);
    var buffer: [1024]u8 align(@alignOf(u64)) = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());

    defer arena.deinit();

    const temporary = arena.allocator();
    const Workspace = if (@hasField(Input, "workspace")) std.meta.Child(@FieldType(Input, "workspace")) else void;
    var buckets: []u64 = &.{};
    const workspace: Workspace = if (Workspace == void) {} else .{ .allocator = @ptrCast(&temporary), .buckets = @ptrCast(&buckets) };
    var input: Input = undefined;

    if (comptime Workspace != void) input.workspace = &workspace;

    const result = (try invoke(Rule, temporary, node, &input)) orelse return null;

    return if (@typeInfo(@TypeOf(result)) == .pointer) result.* else result;
}

fn Finding(comptime Rule: type) type {
    const Present = @typeInfo(Result(Rule)).optional.child;

    return if (@typeInfo(Present) == .pointer) std.meta.Child(Present) else Present;
}

fn Result(comptime Rule: type) type {
    return @typeInfo(@TypeOf(Rule.executeValue(undefined, undefined))).error_union.payload;
}

pub fn at(node: anytype, found: anytype) @TypeOf(node) {
    if (comptime @TypeOf(node) == ast.View) {
        const row: *const ast.Node = @ptrCast(@alignCast(found.rows.ptr));

        return ast.view(row.*);
    }

    return node.schemaNode(@intCast(found.head - 1));
}

pub fn location(node: anytype, found: anytype) ast.Location {
    return at(node, found).location();
}
