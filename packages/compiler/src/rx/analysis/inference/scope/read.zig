const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Scope = @import("../scope.zig");
const errors = @import("../../project/workflow/errors.zig");
const rules = @import("../bindings/rules.zig");
const entry = @import("generated_rx_scope_lookup");
const Input = std.meta.Child(entry.Input);
const Topology = std.meta.Child(@FieldType(Input, "topology"));

pub fn run(graph: *Graph, rows: Scope.Storage.Slice, facts: []const []const u8, name: []const u8, identifier: bool, span: zx.Span) zx.Error!Scope.Reference {
    var parents = graph.parents();

    const query: Input = .{
        .topology = &.{ .graph = &rules.view(Topology, graph), .parents = @ptrCast(&parents) },
        .active = &.{ .names = rows.items(.name), .values = @ptrCast(rows.items(.value)) },
        .name = name,
        .start = 0,
        .facts = facts,
        .identifier = identifier,
    };

    const result = zx.columns.invoke(entry.executeValue, graph.pending.allocator, &query) catch |err| return errors.errorSet(err);

    if (result.candidates) |list| {
        const value = try graph.add(.unknown, span);

        errdefer graph.nodes.len -= 1;

        try graph.pending.binding_lookups.append(graph.pending.allocator, .{
            .candidates = @ptrCast(list),
            .value = value,
            .span = span,
        });

        return .{
            .value = value,
            .implicit_input = result.implicit_input,
            .refined = result.refined,
        };
    }

    return .{
        .value = if (result.value) |id| @fromBackingInt(id) else null,
        .implicit_input = result.implicit_input,
        .refined = result.refined,
    };
}
