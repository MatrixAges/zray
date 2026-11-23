const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("types.zig");
const Expression = @import("expression.zig");
const seed = @import("index/seed.zig");
const Schedule = @import("expression/schedule.zig");

pub const Projection = struct { target: Graph.Id, value: Graph.Id, position: ?u64, span: zx.Span, index_span: zx.Span, resolved: bool = false };

pub fn infer(self: *Expression, item: anytype, span: zx.Span) zx.Error!Graph.Id {
    var target: Graph.Id = undefined;
    var value: Graph.Id = undefined;

    inline for (comptime Schedule.steps(.Index)) |step| {
        switch (step) {
            .Done => {},
            .InferTarget => target = try self.infer(item.target, null),
            .InferPosition => _ = try self.infer(item.index, try self.graph.scalar(.u64, span)),
            .RegisterIndex => {
                value = try self.graph.add(.unknown, span);

                const projection = Projection{
                    .target = target,
                    .value = value,
                    .position = try literalIndex(self, item.index),
                    .span = span,
                    .index_span = self.sourceSpan(item.index.span),
                };

                if (comptime @import("rx_options").generated_graph) {
                    try @import("index/host.zig").register(self.graph, projection);
                } else if (!try seed.propagate(self.graph, projection)) {
                    try self.graph.pending.indexes.append(self.graph.pending.allocator, projection);
                }
            },
            else => unreachable,
        }
    }

    return value;
}

fn literalIndex(self: *Expression, source: anytype) zx.Error!?u64 {
    return switch (syntax.value(source)) {
        .number => |number| try @import("frontend").parseInteger(self.graph.allocator, number),
        else => null,
    };
}
