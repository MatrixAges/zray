const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Graph = @import("../../../inference/types.zig");
const Nodes = @import("../../../inference/nodes.zig");
const SourceMap = @import("../../../source_map.zig");
const Prepared = @import("../../prepare.zig");
const Contracts = @import("../../contracts.zig");
const Ports = @import("../ports.zig");
const Input = @import("../../workflow/solve/abi.zig").Ports;

pub const Frame = struct {
    graph: *Graph = undefined,
    rows: Ports.Slice = undefined,
    input: Input = undefined,
    origins: std.meta.Child(@FieldType(Input, "origins")) = undefined,
    locations: memory.ReadColumn = undefined,
    pub fn bind(self: *Frame, graph: *Graph, rows: Ports.Slice, modules: []const Prepared.Module, source_map: SourceMap, declared: Contracts.Ports) void {
        self.graph = graph;
        self.rows = rows;
        self.locations = memory.borrowNestedColumn(usize, &.{ "source", "node", "location", "offset" }, modules);
        self.origins = .{ .ends = source_map.ends, .locations = @ptrCast(&self.locations) };

        self.input = .{
            .graph = @ptrCast(self),
            .owners = declared.owners,
            .types = @ptrCast(declared.types),
            .modules = modules.len,
            .origins = &self.origins,
        };
    }

    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn commitInferredPorts(handle: *anyopaque, first: u64, end: u64, offsets: []const u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const count = offsets.len;

    std.debug.assert(end - first == count);

    const reservation = try Nodes.reserve(graph, std.math.mul(usize, count, 2) catch return error.OutOfMemory);
    const node_parents = reservation.rows.items(.parent);
    const kinds = reservation.rows.items(.kind);
    const arguments = reservation.rows.items(.argument);
    const members = reservation.rows.items(.members);
    const spans = reservation.rows.items(.span);
    const alloweds = reservation.rows.items(.allowed);
    const fallbacks = reservation.rows.items(.fallback);
    const start: usize = @intCast(first);

    for (offsets, 0..) |offset, index| {
        const node: usize = reservation.first + index * 2;
        const pos: usize = @intCast(offset);
        const span: zx.Span = .{ .start = pos, .end = pos };
        const input_id: u32 = @intCast(node);
        const output_id: u32 = @intCast(node + 1);
        node_parents[node] = input_id;
        node_parents[node + 1] = output_id;
        kinds[node] = .Unknown;
        kinds[node + 1] = .Unknown;
        arguments[node] = 0;
        arguments[node + 1] = 0;
        members[node] = &.{};
        members[node + 1] = &.{};
        spans[node] = span;
        spans[node + 1] = span;
        alloweds[node] = null;
        alloweds[node + 1] = null;
        fallbacks[node] = null;
        fallbacks[node + 1] = null;

        frame.rows.set(start + index, .{
            .input = @fromBackingInt(input_id),
            .output = @fromBackingInt(output_id),
            .input_fixed = false,
        });
    }

    graph.nodes.len = reservation.rows.len;
}

pub fn commitDeclaredPort(handle: *anyopaque, row: u64, input: u32, output: u32, offset: u64) zx.Error!void {
    const frame = Frame.borrow(handle);
    const pos: usize = @intCast(offset);
    const span: zx.Span = .{ .start = pos, .end = pos };

    frame.rows.set(@intCast(row), .{
        .input = try frame.graph.known(@fromBackingInt(input), span),
        .output = try frame.graph.known(@fromBackingInt(output), span),
        .input_fixed = true,
    });
}
