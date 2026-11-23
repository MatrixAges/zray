const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Graph = @import("../../../inference/types.zig");
const Nodes = @import("../../../inference/nodes.zig");
const SourceMap = @import("../../../source_map.zig");
const Prepared = @import("../../prepare.zig");
const Contracts = @import("../../contracts.zig");
const Ports = @import("../ports.zig");
const rule = @import("generated_rx_port_registration");
const Input = std.meta.Child(rule.Input);
const Reservation = std.meta.Child(@FieldType(Input, "reserved"));
const Shape = std.meta.Child(@FieldType(Reservation, "nodes"));
const Columns = std.meta.Child(@FieldType(Shape, "columns"));
const unknown: std.meta.Child(@FieldType(Shape, "shape")) = .{ .kind = @backingInt(Nodes.Kind.Unknown), .argument = 0, .members = &.{} };

const Frame = struct {
    graph: *Graph,
    reservation: Nodes.Reservation,
    parents: []u32 = undefined,
    view: Nodes.Writable = undefined,
    columns: Columns = undefined,
    starts: memory.WriteColumn = undefined,
    ends: memory.WriteColumn = undefined,
    nodes: Shape = undefined,
    fn bind(self: *Frame) void {
        const rows = self.reservation.rows;
        const spans = rows.items(.span);

        self.parents = rows.items(.parent);
        self.view = Nodes.writable(rows);
        self.columns = self.view.borrow(Columns);
        self.starts = memory.borrowWriteColumn(usize, "start", spans);
        self.ends = memory.borrowWriteColumn(usize, "end", spans);

        self.nodes = .{
            .parents = @ptrCast(&self.parents),
            .columns = &self.columns,
            .shape = &unknown,
            .first = self.reservation.first,
            .end = rows.len,
        };
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, rows: Ports.Slice, modules: []const Prepared.Module, source_map: SourceMap, declared: Contracts.Ports) zx.Error!void {
    if (modules.len == 0) return;

    var frame: Frame = .{ .graph = graph, .reservation = .{ .rows = graph.nodes.slice(), .first = graph.nodes.len } };

    frame.bind();

    const locations = memory.borrowNestedColumn(usize, &.{ "source", "node", "location", "offset" }, modules);
    const inputs: []u32 = @ptrCast(rows.items(.input));
    const outputs: []u32 = @ptrCast(rows.items(.output));
    const fixed = rows.items(.input_fixed);
    const binding_ends = rows.items(.binding_end);
    const task_ends = rows.items(.task_end);

    const input: Input = .{
        .graph = @ptrCast(&frame),
        .owners = declared.owners,
        .types = @ptrCast(declared.types),
        .modules = modules.len,
        .origins = &.{ .ends = source_map.ends, .locations = @ptrCast(&locations) },
        .ports = &.{
            .inputs = @ptrCast(&inputs),
            .outputs = @ptrCast(&outputs),
            .fixed = @ptrCast(&fixed),
            .binding_ends = @ptrCast(&binding_ends),
            .task_ends = @ptrCast(&task_ends),
        },
        .reserved = &.{ .nodes = &frame.nodes, .span_starts = @ptrCast(&frame.starts), .span_ends = @ptrCast(&frame.ends) },
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        error.InvalidSource => return error.InvalidSource,
        else => unreachable,
    };
}

pub fn reservePortNodes(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.reservation = try Nodes.reserve(frame.graph, std.math.cast(usize, count) orelse return error.OutOfMemory);

    frame.bind();
}

pub fn commitPortNodes(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.reservation.finish(frame.graph);
}

pub fn internPortType(handle: *const anyopaque, type_id: u32, offset: u64) zx.Error!u32 {
    const graph = Frame.borrow(handle).graph;
    const start: usize = @intCast(offset);

    return @backingInt(try graph.known(@fromBackingInt(type_id), .{ .start = start, .end = start }));
}
