const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Scope = @import("../scope.zig");
const errors = @import("../../project/workflow/errors.zig");
const rules = @import("../bindings/rules.zig");
const entry = @import("generated_rx_scope_lookup");
const Input = std.meta.Child(entry.Input);
const Topology = std.meta.Child(@FieldType(Input, "topology"));
const Deferred = std.meta.Child(@FieldType(Input, "deferred"));
const Node = std.meta.Child(@FieldType(Deferred, "node"));
const Rows = std.meta.Child(@FieldType(Deferred, "rows"));

const Frame = struct {
    graph: *Graph,
    span: zx.Span,
    append: Nodes.Append(Node) = undefined,
    node: Node = undefined,
    rows: Rows = undefined,
    values: []u32 = undefined,
    spans: []zx.Span = undefined,
    length: []usize = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(graph: *Graph, rows: Scope.Storage.Slice, facts: []const []const u8, name: []const u8, identifier: bool, span: zx.Span) zx.Error!Scope.Reference {
    var parents = graph.parents();
    var frame: Frame = .{ .graph = graph, .span = span };

    const query: Input = .{
        .topology = &.{ .graph = &rules.view(Topology, graph), .parents = @ptrCast(&parents) },
        .active = &.{ .names = rows.items(.name), .values = @ptrCast(rows.items(.value)) },
        .name = name,
        .start = 0,
        .facts = facts,
        .identifier = identifier,
        .deferred = &.{ .frame = @ptrCast(&frame), .node = &frame.node, .rows = &frame.rows },
    };

    const result = zx.columns.invoke(entry.executeValue, graph.pending.allocator, &query) catch |err| return errors.errorSet(err);

    if (result.candidates) |list| {
        graph.pending.binding_lookups.items(.candidates)[frame.rows.position] = @ptrCast(list);
    }

    return .{
        .value = if (result.value) |id| @fromBackingInt(id) else null,
        .implicit_input = result.implicit_input,
        .refined = result.refined,
    };
}

pub fn reserveScopeLookupNode(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const reservation = try Nodes.reserve(frame.graph, 1);

    frame.append.bind(&frame.node, frame.graph, reservation, .unknown, frame.span);
}

pub fn reserveScopeLookupRow(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;
    const lookups = &pending.binding_lookups;

    try lookups.ensureUnusedCapacity(pending.allocator, 1);

    var rows = lookups.slice();

    rows.len += 1;
    frame.values = @ptrCast(rows.items(.value));
    frame.spans = rows.items(.span);
    frame.length = (&lookups.len)[0..1];

    frame.rows = .{
        .values = @ptrCast(&frame.values),
        .spans = @ptrCast(&frame.spans),
        .length = @ptrCast(&frame.length),
        .position = lookups.len,
    };
}
