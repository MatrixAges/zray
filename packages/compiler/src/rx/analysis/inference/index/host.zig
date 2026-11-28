const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Projection = @import("../index.zig").Projection;
const Target = @import("../sequences/target.zig");
const errors = @import("../../project/workflow/errors.zig");
const rule = @import("generated_rx_resolve_index");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Effect = std.meta.Child(Store);
const Execution = @import("../../project/workflow/execute.zig");
const Publication = @import("../projections/publish.zig");

pub fn register(graph: *Graph, pending: Projection) zx.Error!void {
    const view = Target.borrow(std.meta.Child(@FieldType(Input, "graph")), graph);

    const site = std.meta.Child(@FieldType(Input, "site")){
        .spans = .Index,
        .row = 0,
    };

    const input: Input = .{
        .site = &site,
        .index_spans = .IndexPosition,
        .graph = &view,
        .target = @backingInt(pending.target),
        .root = @backingInt(graph.root(pending.target)),
        .value = @backingInt(pending.value),
        .position = pending.position,
    };

    const Host = struct {
        graph: *Graph,
        index: *const Projection,
        reply: *Effect,
        store_0: *Store,
        pub fn commit(host: *@This(), changes: rule.zx_pending) zx.Error!void {
            const effect = changes.store_0 orelse return;

            try Publication.commit(host.graph, host.index, effect, host.reply);
        }
    };

    var reply = Execution.snapshot(Effect, .{ .projection_step = .Merge, .id = 0 });
    var store: Store = &reply;
    var host: Host = .{ .graph = graph, .index = &pending, .reply = &reply, .store_0 = &store };
    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, graph.scratch);
    _ = rule.executeIn(scratch.allocator(), &input, &host) catch |err| return errors.errorSet(err);
}
