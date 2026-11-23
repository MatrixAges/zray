const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../inference/types.zig");
const Kind = @import("../../inference/nodes.zig").Kind;

const Frame = struct {
    graph: *Graph,
    resolver: *Graph.Resolver,
};

pub const Columns = struct {
    inputs: []u32,
    outputs: []u32,
    binding_ends: []const u64,
    task_ends: []const u64,
    bindings: []u32,
    tasks: []u32,
};

pub fn run(graph: *Graph, resolver: *Graph.Resolver, columns: Columns) zx.Error!void {
    const rule = @import("generated_rx_publish_signatures");
    const Input = std.meta.Child(rule.Input);
    const Request = std.meta.Child(@FieldType(Input, "columns"));
    const Nodes = std.meta.Child(@FieldType(Request, "nodes"));
    const nodes = graph.nodes.slice();
    const parents = graph.parents();
    const kinds: []const Kind = nodes.items(.kind);
    const frame: Frame = .{ .graph = graph, .resolver = resolver };

    const request: Request = .{
        .nodes = &.{
            .parents = @ptrCast(&parents),
            .kinds = zx.columns.slice(@FieldType(Nodes, "kinds"), kinds),
            .arguments = nodes.items(.argument),
        },
        .ports = &.{
            .inputs = columns.inputs,
            .outputs = columns.outputs,
            .binding_ends = columns.binding_ends,
            .task_ends = columns.task_ends,
        },
        .target = &.{
            .bindings = @ptrCast(&columns.bindings),
            .tasks = @ptrCast(&columns.tasks),
            .inputs = @ptrCast(&columns.inputs),
            .outputs = @ptrCast(&columns.outputs),
        },
    };

    const input: Input = .{ .frame = @ptrCast(&frame), .columns = &request };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../workflow/errors.zig");

    rule.executeIn(scratch.allocator(), &input) catch |err| return workflow.errorSet(err);
}

pub fn resolveSignatureNode(handle: *const anyopaque, node: u32) zx.Error!void {
    const frame: *const Frame = @ptrCast(@alignCast(handle));

    _ = try frame.graph.resolve(@fromBackingInt(node), frame.resolver);
}
