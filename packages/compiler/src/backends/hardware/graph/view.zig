const std = @import("std");
const memory = @import("zx").memory;
const ir = @import("../ir.zig");
const binary = @import("../binary.zig");
const node = @import("node.zig");
const Circuit = @import("circuit.zig");
const validate_graph = @import("generated_validate_hardware_graph");
const native = @import("output_execution_abi").layouts.@"zig:hardware_graph_host";
pub const Scan = std.meta.Child(validate_graph.Input);
const Graph = std.meta.Child(@FieldType(Scan, "graph"));
const Ports = std.meta.Child(@FieldType(Graph, "inputs"));
const Sorts = std.meta.Child(@FieldType(Graph, "sorts"));
const Self = @This();

input_columns: PortColumns,
output_columns: PortColumns,
widths: memory.ReadColumn,
booleans: memory.ReadColumn,
inputs: Ports,
outputs: Ports,
sorts: Sorts,
graph: Graph,
nodes: Nodes,

const Nodes = union(enum) {
    direct: []const node.Row,
    legacy: struct {
        nodes: []const ir.Node,
        current: node.Node = undefined,
    },
};

const PortColumns = struct {
    names: memory.TextColumn,
    widths: memory.ReadColumn,
    booleans: memory.ReadColumn,
    nodes: memory.ReadColumn,
    signed: memory.ReadColumn,
    fn init(ports: []const ir.Port) PortColumns {
        return .{
            .names = memory.borrowTextColumn("name", ports),
            .widths = memory.borrowNestedColumn(u16, &.{ "sort", "width" }, ports),
            .booleans = memory.borrowNestedColumn(bool, &.{ "sort", "boolean" }, ports),
            .nodes = memory.borrowReadColumn(ir.Id, "node", ports),
            .signed = memory.borrowReadColumn(bool, "signed", ports),
        };
    }
    fn view(self: *const PortColumns) Ports {
        return .{
            .count = self.names.count,
            .names = @ptrCast(&self.names),
            .widths = @ptrCast(&self.widths),
            .booleans = @ptrCast(&self.booleans),
            .nodes = @ptrCast(&self.nodes),
            .signed = @ptrCast(&self.signed),
        };
    }
};

/// Binds the borrowed column descriptors in place for this graph's synchronous consumers.
pub fn init(self: *Self, module: anytype) void {
    self.input_columns = .init(module.inputs);
    self.output_columns = .init(module.outputs);

    if (@TypeOf(module) == Circuit) {
        self.widths = memory.borrowNestedColumn(u16, &.{ "node", "width" }, module.nodes);
        self.booleans = memory.borrowNestedColumn(bool, &.{ "node", "boolean" }, module.nodes);
        self.nodes = .{ .direct = module.nodes };
    } else {
        self.widths = memory.borrowNestedColumn(u16, &.{ "sort", "width" }, module.nodes);
        self.booleans = memory.borrowNestedColumn(bool, &.{ "sort", "boolean" }, module.nodes);
        self.nodes = .{ .legacy = .{ .nodes = module.nodes } };
    }

    self.inputs = self.input_columns.view();
    self.outputs = self.output_columns.view();
    self.sorts = .{ .widths = @ptrCast(&self.widths), .booleans = @ptrCast(&self.booleans) };
    self.graph = .{ .inputs = &self.inputs, .outputs = &self.outputs, .sorts = &self.sorts, .count = module.nodes.len, .safe = @backingInt(module.safe) };
}

pub fn scan(self: *const Self) Scan {
    return .{ .graph = &self.graph, .nodes = @ptrCast(&self.nodes) };
}

pub fn validate(self: *const Self) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return validate_graph.executeIn(empty.allocator(), &self.scan()) catch unreachable;
}

pub fn readHardwareGraphNode(handle: *const anyopaque, index: u64) *const node.Node {
    const nodes: *Nodes = @ptrCast(@alignCast(@constCast(handle)));
    const row: usize = @intCast(index);

    return switch (nodes.*) {
        .direct => |rows| &rows[row].node,
        .legacy => |*legacy| value: {
            legacy.current = node.fromLegacy(&legacy.nodes[row]);

            break :value &legacy.current;
        },
    };
}

pub fn hardwareTermOperator(text: []const u8) ?u8 {
    const operator = binary.names.get(text) orelse return null;

    return @intCast(@backingInt(operator));
}

pub fn hardwareTermFamily(operator: u8) native.Family {
    return @fromBackingInt(@backingInt(binary.traits(@fromBackingInt(@intCast(operator))).family));
}

pub fn hardwareTermRendering(operator: u8) native.Rendering {
    return @fromBackingInt(@backingInt(binary.traits(@fromBackingInt(@intCast(operator))).rendering));
}

pub fn hardwareTermToken(operator: u8) []const u8 {
    return binary.traits(@fromBackingInt(@intCast(operator))).token;
}
