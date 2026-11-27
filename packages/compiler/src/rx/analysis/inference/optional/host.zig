const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Known = @import("../known.zig");
const Topology = @import("topology.zig").borrowType;
const errors = @import("../../project/workflow/errors.zig");
const rule = @import("generated_rx_optional_query");
const Input = std.meta.Child(rule.Input);
const View = std.meta.Child(@FieldType(Input, "view"));

const Frame = struct {
    graph: *Graph,
    topology: Topology(View) = undefined,
    view: View = undefined,
    spans: []const zx.Span = undefined,
    remaining: u64 = undefined,
    fn bind(self: *Frame) void {
        const rows = self.graph.nodes.slice();

        self.topology.bind(self.graph);

        self.spans = rows.items(.span);

        self.view = .{
            .graph = &self.topology.graph,
            .known = &self.topology.known,
            .parents = @ptrCast(&self.topology.parents),
            .allowed = rows.items(.allowed),
        };
    }
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(comptime mode: @FieldType(Input, "mode"), graph: *Graph, source: Graph.Id) zx.Error!?Graph.Id {
    var frame: Frame = .{ .graph = graph };

    frame.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .view = &frame.view,
        .mode = mode,
        .value = @backingInt(source),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| return errors.errorSet(err);

    if (result.diagnostic) |issue| return graph.reporter.fail(.unsupported, frame.spans[issue.root], issue.message);

    return if (result.value) |id| @fromBackingInt(id) else null;
}

pub fn registerOptionalPayload(handle: *anyopaque, root: u32, value: u32, remaining: u64) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const result = try Known.registerPayload(frame.graph, value, remaining, frame.spans[root]);

    frame.remaining = result.remaining;

    return @backingInt(result.node);
}

pub fn remainingOptionalDepth(handle: *anyopaque) u64 {
    return Frame.borrow(handle).remaining;
}

pub fn refreshOptionalQuery(handle: *anyopaque) void {
    Frame.borrow(handle).bind();
}
