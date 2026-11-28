const zx = @import("zx");
const Graph = @import("../types.zig");
const Access = @import("../fields/access.zig");
const Index = @import("../index.zig").Projection;
const Registration = @import("../assignment/registration.zig");

pub fn commit(graph: *Graph, immediate: ?*const Index, effect: anytype, reply: anytype) zx.Error!void {
    switch (effect.projection_step) {
        .AppendIndex => try graph.pending.indexes.append(graph.pending.allocator, immediate.?.*),
        .ExpectSequence => {
            const sequence = graph.pending.sequences.get(@intCast(effect.site.?.row));

            const targets: Registration.Targets = if (effect.repeated) |child|
                .{ .repeated = @fromBackingInt(child) }

            else if (effect.declared.?)
                .{ .declared = effect.members.? }
            else
                .{ .inferred = effect.members.? };

            try Registration.expectMany(graph, sequence.elements, sequence.spans, targets);
        },
        .RegisterType => {
            const id = try graph.known(@fromBackingInt(effect.left.?), span(graph, immediate, effect.site.?));

            reply.id = @backingInt(id);
        },
        .Merge => try graph.unify(@fromBackingInt(effect.left.?), @fromBackingInt(effect.right.?), span(graph, immediate, effect.site.?)),
        .RequireList => {
            const id = try graph.payload(@fromBackingInt(effect.left.?), .list, span(graph, immediate, effect.site.?));

            reply.id = @backingInt(id);
        },
        .ReadLength => {
            const id = try Access.open(graph, @fromBackingInt(effect.left.?), Access.length_name, span(graph, immediate, effect.site.?));

            reply.id = @backingInt(id);
        },
        .Reject => return graph.reporter.fail(
            if (effect.unsupported.?) .unsupported else .type_mismatch,
            span(graph, immediate, effect.site.?),
            effect.message.?,
        ),
    }
}

fn span(graph: *const Graph, immediate: ?*const Index, site: anytype) zx.Span {
    const row: usize = @intCast(site.row);

    return switch (site.spans) {
        .Node => graph.nodes.items(.span)[row],
        .Assignment => graph.pending.assignments.items(.span)[row],
        .Length => graph.pending.lengths.items(.span)[row],
        .Index => if (immediate) |entry| entry.span else graph.pending.indexes.items(.span)[row],
        .IndexPosition => if (immediate) |entry| entry.index_span else graph.pending.indexes.items(.index_span)[row],
        .Sequence => graph.pending.sequences.items(.span)[row],
        .SequenceElement => graph.pending.sequences.items(.spans)[row][0],
        .Selection => graph.pending.selections.items(.span)[row],
    };
}
