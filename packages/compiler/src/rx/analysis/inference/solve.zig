const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Frame = @import("solve/host.zig").Frame;

pub fn finish(graph: *Graph, resolver: *Graph.Resolver) zx.Error!void {
    var frame: Frame = .{
        .graph = graph,
        .resolver = resolver,
        .workspace = .init(graph.scratch),
        .closure = .init(graph.scratch),
    };

    defer frame.workspace.deinit();
    defer frame.closure.deinit();

    if (comptime @import("rx_options").generated_graph) {
        const workflow = @import("../project/workflow/errors.zig");
        const rule = @import("generated_rx_run_constraint_solver");
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(rule.Input) = .{
            .frame = @ptrCast(&frame),
            .bindings = &frame.bindings.view,
        };

        return rule.executeIn(scratch.allocator(), &input) catch |err| workflow.errorSet(err);
    }

    return @import("solve/seed.zig").run(&frame);
}
