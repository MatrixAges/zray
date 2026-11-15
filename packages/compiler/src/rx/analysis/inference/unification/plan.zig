const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Occurs = @import("occurs.zig");
pub const enabled = @import("rx_options").generated_graph;
const generated = if (enabled) @import("generated_rx_unification_prepare") else void;
const Output = if (enabled) @typeInfo(@typeInfo(@TypeOf(generated.executeValue)).@"fn".return_type.?).error_union.payload else void;

pub const Route = if (enabled) @FieldType(Output, "route") else enum {
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

pub const Action = if (enabled) @FieldType(Output, "action") else void;

pub const Work = if (enabled) Output else struct {
    left: u32,
    right: u32,
    route: Route,
};

pub fn prepare(graph: *const Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!Work {
    if (!enabled) return prepareSeed(graph, left, right, span, depth);

    return prepareGenerated(generated, graph, left, right, depth);
}

pub fn rooted(graph: *const Graph, left: Graph.Id, right: Graph.Id) zx.Error!Work {
    return prepareGenerated(@import("generated_rx_unification_rooted"), graph, left, right, 0);
}

fn prepareGenerated(comptime rule: type, graph: *const Graph, left: Graph.Id, right: Graph.Id, depth: usize) zx.Error!Work {
    const rows = graph.nodes.slice();
    const types = &graph.types.items;
    const parents: []u32 = graph.parents();
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const Input = std.meta.Child(rule.Input);

    const graph_view: std.meta.Child(@FieldType(Input, "graph")) = .{
        .kinds = rows.items(.kind),
        .members = rows.items(.members),
        .arguments = rows.items(.argument),
    };

    const type_view: std.meta.Child(@FieldType(Input, "types")) = .{
        .kinds = types.kinds.items,
        .arguments = types.first.items,
        .sizes = types.second.items,
        .children = types.children.items,
        .field_values = types.field_types.items,
        .field_names = types.field_names.items,
    };

    var input: Input = undefined;

    input.graph = &graph_view;
    input.types = &type_view;
    input.parents = @ptrCast(&parents);
    input.left = @backingInt(left);
    input.right = @backingInt(right);

    if (comptime @hasField(Input, "depth")) input.depth = depth;
    if (comptime @hasField(Input, "zx_origin")) input.zx_origin = null;

    const request: *const Input = &input;

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn prepareSeed(graph: *const Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!Work {
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
    if (!enabled) {
        for (names, 0..) |name, index| {
            if (std.mem.eql(u8, name, key)) return index;
        }

        return null;
    }

    var bytes: [0]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&bytes);
    const index = @import("generated_rx_unification_field").executeIn(scratch.allocator(), &.{ .names = names, .name = key }) catch unreachable;

    return if (index) |value| @intCast(value) else null;
}
