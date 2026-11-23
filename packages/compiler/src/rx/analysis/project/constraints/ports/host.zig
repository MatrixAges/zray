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
const Reservation = std.meta.Child(@FieldType(Input, "reserved"));
const Shape = std.meta.Child(@FieldType(Reservation, "nodes"));
const Storage = std.meta.Child(@FieldType(Reservation, "storage"));
const Columns = std.meta.Child(@FieldType(Shape, "columns"));
const unknown: std.meta.Child(@FieldType(Shape, "shape")) = .{ .kind = @backingInt(Nodes.Kind.Unknown), .argument = 0, .members = &.{} };

pub const Frame = struct {
    graph: *Graph = undefined,
    reservation: Nodes.Reservation = undefined,
    input: Input = undefined,
    port_columns: std.meta.Child(@FieldType(Input, "ports")) = undefined,
    origins: std.meta.Child(@FieldType(Input, "origins")) = undefined,
    reserved: Reservation = undefined,
    locations: memory.ReadColumn = undefined,
    inputs: []u32 = undefined,
    outputs: []u32 = undefined,
    fixed: []bool = undefined,
    binding_ends: []u64 = undefined,
    task_ends: []u64 = undefined,
    parents: []u32 = undefined,
    view: Nodes.Writable = undefined,
    columns: Columns = undefined,
    starts: memory.WriteColumn = undefined,
    ends: memory.WriteColumn = undefined,
    nodes: Shape = undefined,
    publication: Nodes.Publication = undefined,
    storage: Storage = undefined,
    fn bindNodes(self: *Frame) void {
        const rows = self.reservation.rows;
        const spans = rows.items(.span);

        self.parents = rows.items(.parent);
        self.view = Nodes.writable(rows);
        self.columns = self.view.borrow(Columns);
        self.starts = memory.borrowWriteColumn(usize, "start", spans);
        self.ends = memory.borrowWriteColumn(usize, "end", spans);
        self.publication = Nodes.Publication.init(self.graph, rows);
        self.storage = self.publication.storage(Storage);

        self.nodes = .{
            .parents = @ptrCast(&self.parents),
            .columns = &self.columns,
            .shape = &unknown,
            .first = self.reservation.first,
            .end = rows.len,
        };
    }

    pub fn bind(self: *Frame, graph: *Graph, rows: Ports.Slice, modules: []const Prepared.Module, source_map: SourceMap, declared: Contracts.Ports) void {
        self.graph = graph;
        self.reservation = .{ .rows = graph.nodes.slice(), .first = graph.nodes.len };

        self.bindNodes();

        self.locations = memory.borrowNestedColumn(usize, &.{ "source", "node", "location", "offset" }, modules);
        self.inputs = @ptrCast(rows.items(.input));
        self.outputs = @ptrCast(rows.items(.output));
        self.fixed = rows.items(.input_fixed);
        self.binding_ends = rows.items(.binding_end);
        self.task_ends = rows.items(.task_end);

        self.port_columns = .{
            .inputs = @ptrCast(&self.inputs),
            .outputs = @ptrCast(&self.outputs),
            .fixed = @ptrCast(&self.fixed),
            .binding_ends = @ptrCast(&self.binding_ends),
            .task_ends = @ptrCast(&self.task_ends),
        };

        self.origins = .{ .ends = source_map.ends, .locations = @ptrCast(&self.locations) };

        self.reserved = .{
            .nodes = &self.nodes,
            .span_starts = @ptrCast(&self.starts),
            .span_ends = @ptrCast(&self.ends),
            .storage = &self.storage,
        };

        self.input = .{
            .graph = @ptrCast(self),
            .owners = declared.owners,
            .types = @ptrCast(declared.types),
            .modules = modules.len,
            .origins = &self.origins,
            .ports = &self.port_columns,
            .reserved = &self.reserved,
        };
    }

    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn reservePortNodes(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.reservation = try Nodes.reserve(frame.graph, std.math.cast(usize, count) orelse return error.OutOfMemory);

    frame.bindNodes();
}

pub fn internPortType(handle: *const anyopaque, type_id: u32, offset: u64) zx.Error!u32 {
    const graph = Frame.borrow(handle).graph;
    const start: usize = @intCast(offset);

    return @backingInt(try graph.known(@fromBackingInt(type_id), .{ .start = start, .end = start }));
}
