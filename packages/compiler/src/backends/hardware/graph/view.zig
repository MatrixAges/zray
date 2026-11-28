const std = @import("std");
const memory = @import("zx").memory;
const ir = @import("../ir.zig");
const node = @import("node.zig");
const Circuit = @import("circuit.zig");
const validate_graph = @import("generated_validate_hardware_graph");
pub const Scan = std.meta.Child(validate_graph.Input);
const Graph = std.meta.Child(@FieldType(Scan, "graph"));
const Ports = std.meta.Child(@FieldType(Graph, "inputs"));
const Sorts = std.meta.Child(@FieldType(Graph, "sorts"));
const NodeColumns = std.meta.Child(@FieldType(Scan, "nodes"));
const node_fields = @typeInfo(NodeColumns).@"struct".field_names;
const Self = @This();

input_columns: PortColumns,
output_columns: PortColumns,
inputs: Ports,
outputs: Ports,
sorts: Sorts,
graph: Graph,
nodes: NodeColumns,
node_columns: [node_fields.len]memory.ReadColumn,
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
pub fn init(self: *Self, allocator: std.mem.Allocator, module: anytype) std.mem.Allocator.Error!void {
    self.input_columns = .init(module.inputs);
    self.output_columns = .init(module.outputs);

    if (@TypeOf(module) == Circuit) {
        self.bindNodes(module.nodes);
    } else {
        const rows = try allocator.alloc(node.Node, module.nodes.len);

        for (module.nodes, rows) |*legacy, *flat| flat.* = node.fromLegacy(legacy);

        self.bindNodes(@as([]const node.Node, rows));
    }

    self.inputs = self.input_columns.view();
    self.outputs = self.output_columns.view();
    self.sorts = .{ .widths = self.nodes.width, .booleans = self.nodes.boolean };
    self.graph = .{ .inputs = &self.inputs, .outputs = &self.outputs, .sorts = &self.sorts, .count = module.nodes.len, .safe = @backingInt(module.safe) };
}

fn bindNodes(self: *Self, rows: anytype) void {
    const nested = std.meta.Elem(@TypeOf(rows)) == node.Row;

    inline for (node_fields, 0..) |name, index| {
        const Member = @FieldType(node.Node, name);

        self.node_columns[index] = if (nested)
            memory.borrowNestedColumn(Member, &.{ "node", name }, rows)

        else
            memory.borrowReadColumn(Member, name, rows);

        @field(self.nodes, name) = @ptrCast(&self.node_columns[index]);
    }
}

pub fn scan(self: *const Self) Scan {
    return .{ .graph = &self.graph, .nodes = &self.nodes };
}

pub fn validate(self: *const Self, allocator: std.mem.Allocator) bool {
    return validate_graph.executeIn(allocator, &self.scan()) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => false,
        else => unreachable,
    };
}
