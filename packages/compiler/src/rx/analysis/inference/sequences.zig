const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("types.zig");
const Expression = @import("expression.zig");
const Schedule = @import("expression/schedule.zig");
const Target = @import("sequences/target.zig");
const Registration = @import("assignment/registration.zig");
const generated = @import("rx_options").generated_graph;

pub const Sequence = struct { value: Graph.Id, elements: []const Graph.Id, spans: []const zx.Span, span: zx.Span };

const Elements = std.MultiArrayList(struct { element: Graph.Id, span: zx.Span });

pub fn infer(self: *Expression, items: anytype, expected: ?Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    var value: Graph.Id = undefined;
    var rows: Elements.Slice = undefined;

    inline for (comptime Schedule.steps(.Sequence)) |step| {
        switch (step) {
            .Done => {},
            .SequenceResult => value = try self.graph.add(.sequence, span),
            .ExpectResult => if (expected) |target| try self.graph.expect(value, target, span),
            .InferElements => rows = try inferElements(self, items),
            .RegisterSequence => try self.graph.pending.sequences.append(self.graph.pending.allocator, .{
                .value = value,
                .elements = rows.items(.element),
                .spans = rows.items(.span),
                .span = span,
            }),
            else => unreachable,
        }
    }

    return value;
}

fn inferElements(self: *Expression, items: anytype) zx.Error!Elements.Slice {
    var storage: Elements = .empty;

    try storage.setCapacity(self.graph.pending.allocator, items.len);

    storage.len = items.len;

    const rows = storage.slice();
    const elements = rows.items(.element);
    const spans = rows.items(.span);

    for (elements, 0..) |*element, index| {
        const item = syntax.item(items, index);

        spans[index] = self.sourceSpan(item.span);
        element.* = try self.infer(item, null);
    }

    return rows;
}

pub fn replay(graph: *Graph) zx.Error!void {
    const sequences = graph.pending.sequences.slice();

    if (comptime !generated) {
        for (0..sequences.len) |row| try seedPropagate(graph, sequences.get(row));

        return;
    }

    try @import("sequences/host.zig").run(graph, sequences);
}

fn seedPropagate(graph: *Graph, sequence: Sequence) zx.Error!void {
    const target = Target.Seed.read(graph, sequence.value);

    switch (target.sequenceRoute(sequence.elements.len)) {
        .Wait => return,
        .Length => return lengthMismatch(graph, sequence.span),
        .Invalid => return invalidSequence(graph, sequence.span),
        .List => {
            const child = target.member(0);

            try expectList(graph, sequence, child.value, child.declared);
        },
        .Tuple => for (sequence.elements, sequence.spans, 0..) |element, span, index| {
            const child = target.member(index);

            try graph.expect(element, try Target.child(graph, child.value, child.declared, span), span);
        },
    }
}

pub fn expectList(graph: *Graph, sequence: Sequence, child: u32, declared: bool) zx.Error!void {
    if (sequence.elements.len == 0) return;

    const member = try Target.child(graph, child, declared, sequence.spans[0]);

    if (generated) return Registration.expectMany(graph, sequence.elements, sequence.spans, .{ .repeated = member });
    for (sequence.elements, sequence.spans) |element, span| try graph.expect(element, member, span);
}

pub fn lengthMismatch(graph: *const Graph, span: zx.Span) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, "tuple element count does not match the required type");
}

pub fn invalidSequence(graph: *const Graph, span: zx.Span) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, "a sequence requires a list or tuple type");
}
