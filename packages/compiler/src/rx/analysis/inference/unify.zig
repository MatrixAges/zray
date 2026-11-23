const zx = @import("zx");
const Graph = @import("types.zig");
const Nodes = @import("nodes.zig");
const Plan = @import("unification/plan.zig");
const Commit = @import("unification/commit.zig");
const Occurs = @import("unification/occurs.zig");
const Frame = @import("unify/frame.zig");

pub const Pending = struct { frame: Frame, declared_names: []const []const u8 };

pub fn merge(graph: *Graph, left: Graph.Id, right: Graph.Id, span: zx.Span, depth: usize) zx.Error!void {
    if (comptime !Plan.enabled) return @import("unify/seed.zig").merge(graph, left, right, span, depth);

    const work = try Plan.prepare(graph, left, right, span, depth);
    const frame = try prepare(graph, work, span) orelse return;

    return @import("unify/host.zig").walk(graph, frame, span, depth);
}

pub fn prepare(graph: *Graph, work: Plan.Work, span: zx.Span) zx.Error!?Pending {
    switch (work.route) {
        .Same => return null,
        .Depth => return Occurs.depthLimit(graph, span),
        .Recursive => return Occurs.recursive(graph, span),
        .Left, .Right, .Known, .Child, .Tuple, .Object => {},
        else => |issue| return graph.reporter.fail(.type_mismatch, span, @import("unify/messages.zig").shape(issue)),
    }

    const rows = graph.nodes.slice();
    const parent: Graph.Id = @fromBackingInt(work.left);
    const child: Graph.Id = @fromBackingInt(work.right);
    const first = Commit.snapshot(rows, parent);
    const second = Commit.snapshot(rows, child);
    const shape = Nodes.encoded(rows, work.source);

    if (work.action == .Adopt) {
        try Commit.publish(graph, parent, child, first, second, shape, span);

        return null;
    }

    return .{
        .frame = .{
            .parent = parent,
            .child = child,
            .action = work.action,
            .left_operand = work.left_operand,
            .right_operand = work.right_operand,
            .first = first,
            .second = second,
            .shape = shape,
            .left_members = work.left_members,
            .right_members = work.right_members,
        },
        .declared_names = work.right_names,
    };
}
