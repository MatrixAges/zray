const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Scalar = @import("../scalar.zig");
const Nodes = @import("../nodes.zig");
const seed = @import("seed.zig");
const enabled = @import("rx_options").generated_graph;
const entry = if (enabled) @import("generated_rx_scalar_restriction") else void;
const Input = if (enabled) std.meta.Child(entry.Input) else void;
const Target = if (enabled) std.meta.Child(@FieldType(Input, "target")) else void;
pub const View = if (enabled) std.meta.Child(@FieldType(Target, "graph")) else void;

pub fn borrow(graph: *const Graph, parents: *[]u32) View {
    const rows = graph.nodes.slice();
    const types = &graph.types.items;

    return .{
        .parents = @ptrCast(parents),
        .kinds = rows.items(.kind),
        .arguments = rows.items(.argument),
        .allowed = rows.items(.allowed),
        .type_kinds = types.kinds.items,
        .type_arguments = types.first.items,
    };
}

pub fn restrict(graph: *Graph, id: Graph.Id, allowed: Scalar.Mask, span: zx.Span) zx.Error!void {
    if (!enabled) return restrictSeed(graph, id, allowed, span);

    var parents: []u32 = graph.parents();
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .target = &.{ .graph = &borrow(graph, &parents), .node = @backingInt(id) },
        .requested = allowed.bits.mask,
    };

    const outcome = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable;

    if (outcome.allowed) |mask| graph.nodes.items(.allowed)[outcome.root] = mask;
    if (outcome.changed) graph.revision += 1;
    if (outcome.message) |text| return graph.reporter.fail(.type_mismatch, span, text);
}

fn restrictSeed(graph: *Graph, id: Graph.Id, allowed: Scalar.Mask, span: zx.Span) zx.Error!void {
    const index = @backingInt(graph.root(id));
    const current = graph.shapeAt(index);
    const rows = graph.nodes.slice();

    const scalar: ?zx.ir.Scalar = if (current == .known) switch (graph.types.get(current.known)) {
        .scalar => |value| value,
        else => null,
    } else null;

    const shape: Scalar.Shape = switch (current) {
        .unknown => .open,
        .known => if (scalar != null) .scalar else .concrete,
        else => .structure,
    };

    const merged = seed.restrict(Nodes.allowed(rows, index), allowed, shape, scalar);

    if (merged.issue != .none) return failure(graph, merged.issue, span);

    const bits: u16 = @intCast(merged.allowed.bits.mask);
    const previous = &rows.items(.allowed)[index];

    if (previous.* == null or previous.*.? != bits) graph.revision += 1;

    previous.* = bits;
}

fn failure(graph: *const Graph, issue: Scalar.Issue, span: zx.Span) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, switch (issue) {
        .empty => "incompatible inferred scalar requirements",
        .operator => "inferred type does not satisfy the operator",
        .structure => "the operator requires a scalar value",
        .none => unreachable,
    });
}
