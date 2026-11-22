const ir = @import("../ir.zig");
const native = @import("output_execution_abi").layouts.@"zig:hardware_graph_host";
pub const Node = native.Node;

pub const Row = struct {
    node: Node,
    origin: ?ir.Origin,
};

pub fn fromLegacy(source: *const ir.Node) Node {
    var result: Node = .{
        .kind = undefined,
        .width = source.sort.width,
        .boolean = source.sort.boolean,
        .first = undefined,
        .second = 0,
        .third = 0,
        .operator = 0,
        .extra = 0,
        .signed = false,
    };

    switch (source.value) {
        .input => |value| {
            result.kind = .Input;
            result.first = value;
        },
        .constant => |value| {
            result.kind = .Constant;
            result.first = value;
        },
        .invert => |value| {
            result.kind = .Invert;
            result.first = @backingInt(value);
        },
        .negate => |value| {
            result.kind = .Negate;
            result.first = @backingInt(value);
        },
        .binary => |value| {
            result.kind = .Binary;
            result.first = @backingInt(value.left);
            result.second = @backingInt(value.right);
            result.operator = @intCast(@backingInt(value.operator));
        },
        .select => |value| {
            result.kind = .Select;
            result.first = @backingInt(value.condition);
            result.second = @backingInt(value.yes);
            result.third = @backingInt(value.no);
        },
        .extend => |value| {
            result.kind = .Extend;
            result.first = @backingInt(value.operand);
            result.extra = value.extra;
            result.signed = value.signed;
        },
    }

    return result;
}

pub fn legacy(node: *const Node, origin: ?ir.Origin) ir.Node {
    return .{
        .sort = .{ .width = node.width, .boolean = node.boolean },
        .origin = origin,
        .value = switch (node.kind) {
            .Input => .{ .input = @intCast(node.first) },
            .Constant => .{ .constant = node.first },
            .Invert => .{ .invert = id(node.first) },
            .Negate => .{ .negate = id(node.first) },
            .Binary => .{ .binary = .{ .operator = @fromBackingInt(@intCast(node.operator)), .left = id(node.first), .right = @fromBackingInt(node.second) } },
            .Select => .{ .select = .{ .condition = id(node.first), .yes = @fromBackingInt(node.second), .no = @fromBackingInt(node.third) } },
            .Extend => .{ .extend = .{ .operand = id(node.first), .signed = node.signed, .extra = node.extra } },
        },
    };
}

fn id(index: u64) ir.Id {
    return @fromBackingInt(@as(u32, @intCast(index)));
}
