const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Known = @import("../known.zig");
const Topology = @import("topology.zig").borrowType;
const errors = @import("../../project/workflow/errors.zig");
const rule = @import("generated_rx_optional_query");
const Input = std.meta.Child(rule.Input);
const View = std.meta.Child(@FieldType(Input, "view"));
const Store = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Effect = std.meta.Child(Store);

const Frame = struct {
    graph: *Graph,
    topology: Topology(View) = undefined,
    view: View = undefined,
    spans: []const zx.Span = undefined,
    fn bind(self: *Frame) void {
        const rows = self.graph.nodes.slice();

        self.topology.bind(self.graph);

        self.spans = rows.items(.span);

        self.view = .{
            .graph = &self.topology.graph,
            .known = &self.topology.known,
            .parents = self.topology.parents,
            .allowed = rows.items(.allowed),
        };
    }
};

pub fn run(comptime mode: @FieldType(Input, "mode"), graph: *Graph, source: Graph.Id) zx.Error!?Graph.Id {
    var frame: Frame = .{ .graph = graph };

    frame.bind();

    const input: Input = .{
        .view = &frame.view,
        .mode = mode,
        .value = @backingInt(source),
    };

    const Host = struct {
        frame: *Frame,
        reply: *Effect,
        store_0: *Store,
        pub fn commit(host: *@This(), pending: rule.zx_pending) zx.Error!void {
            const command = pending.store_0 orelse return;
            const current = host.frame;
            const result = try Known.registerPayload(current.graph, command.value, command.remaining, current.spans[command.root]);

            current.bind();

            host.reply.* = .{
                .root = command.root,
                .value = @backingInt(result.node),
                .remaining = result.remaining,
            };
        }
    };

    var reply: Effect = .{ .root = 0, .value = 0, .remaining = 0 };
    var store: Store = &reply;
    var host: Host = .{ .frame = &frame, .reply = &reply, .store_0 = &store };
    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, graph.scratch);
    const result = rule.executeIn(scratch.allocator(), &input, &host) catch |err| return errors.errorSet(err);

    if (result.diagnostic) |issue| return graph.reporter.fail(.unsupported, frame.spans[issue.root], issue.message);

    return if (result.value) |id| @fromBackingInt(id) else null;
}
