const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Occurs = @import("occurs.zig");

pub const Route = enum {
    Ready,
    Same,
    Depth,
    Recursive,
    Left,
    Right,
    Known,
    Child,
    Tuple,
    Object,
    SequenceMismatch,
    ShapeMismatch,
    TupleMismatch,
    ConcreteMismatch,
    ConcreteObjectMismatch,
    ConcreteContainerMismatch,
    ConcreteTupleMismatch,
};

pub const Work = struct {
    left: u32,
    right: u32,
    route: Route,
};

pub fn prepare(graph: *const Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!Work {
    if (depth >= 256) return .{ .left = @backingInt(left), .right = @backingInt(right), .route = .Depth };

    const a = graph.root(left);
    const b = graph.root(right);

    if (a == b) return .{ .left = @backingInt(a), .right = @backingInt(b), .route = .Same };
    try Occurs.check(graph, a, b, span);

    const first = graph.shapeAt(@backingInt(a));
    const second = graph.shapeAt(@backingInt(b));

    return .{
        .left = @backingInt(a),
        .right = @backingInt(b),
        .route = seed(first, second, concreteType(graph, first, second)),
    };
}

pub fn concreteType(graph: *const Graph, left: Graph.Shape, right: Graph.Shape) ?zx.ir.Type {
    if (left == .known and right != .unknown and right != .known) return graph.types.get(left.known);
    if (right == .known and left != .unknown and left != .known) return graph.types.get(right.known);

    return null;
}

fn seed(left: Graph.Shape, right: Graph.Shape, concrete: ?zx.ir.Type) Route {
    if (left == .unknown) return .Right;
    if (right == .unknown) return .Left;

    if (left == .known or right == .known) {
        const declared = if (left == .known) left else right;
        const inferred = if (left == .known) right else left;

        return switch (inferred) {
            .known => |id| if (declared.known == id) .Known else .ConcreteMismatch,
            .sequence => if (concrete.? == .list or concrete.? == .tuple) .Known else .SequenceMismatch,
            .object => if (concrete.? == .object) .Known else .ConcreteObjectMismatch,
            .list => if (concrete.? == .list) .Known else .ConcreteContainerMismatch,
            .optional => if (concrete.? == .optional) .Known else .ConcreteContainerMismatch,
            .tuple => |items| if (concrete.? == .tuple and concrete.?.tuple.len == items.len) .Known else .ConcreteTupleMismatch,
            .unknown => unreachable,
        };
    }

    if (left == .sequence) return if (right == .sequence or right == .list or right == .tuple) .Right else .SequenceMismatch;
    if (right == .sequence) return if (left == .list or left == .tuple) .Left else .SequenceMismatch;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return .ShapeMismatch;

    return switch (left) {
        .list, .optional => .Child,
        .tuple => if (left.tuple.len == right.tuple.len) .Tuple else .TupleMismatch,
        .object => .Object,
        else => unreachable,
    };
}

pub fn position(names: []const []const u8, key: []const u8) ?usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, key)) return index;
    }

    return null;
}
