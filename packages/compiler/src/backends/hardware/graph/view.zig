const std = @import("std");
const memory = @import("zx").memory;
const ir = @import("../ir.zig");
const binary = @import("../binary.zig");
const check = @import("generated_hardware_graph_node");
const endpoints = @import("generated_hardware_graph_ports");
const Check = std.meta.Child(check.Input);
const Graph = std.meta.Child(@FieldType(Check, "graph"));
const Ports = std.meta.Child(@FieldType(Graph, "inputs"));
const Sorts = std.meta.Child(@FieldType(Graph, "sorts"));
const Node = std.meta.Child(@FieldType(Check, "node"));
const Self = @This();

input_columns: PortColumns,
output_columns: PortColumns,
widths: memory.ReadColumn,
booleans: memory.ReadColumn,
inputs: Ports,
outputs: Ports,
sorts: Sorts,
graph: Graph,
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
pub fn init(self: *Self, module: ir.Module) void {
    self.input_columns = .init(module.inputs);
    self.output_columns = .init(module.outputs);
    self.widths = memory.borrowNestedColumn(u16, &.{ "sort", "width" }, module.nodes);
    self.booleans = memory.borrowNestedColumn(bool, &.{ "sort", "boolean" }, module.nodes);
    self.inputs = self.input_columns.view();
    self.outputs = self.output_columns.view();
    self.sorts = .{ .widths = @ptrCast(&self.widths), .booleans = @ptrCast(&self.booleans) };
    self.graph = .{ .inputs = &self.inputs, .outputs = &self.outputs, .sorts = &self.sorts, .count = module.nodes.len, .safe = @backingInt(module.safe) };
}

pub fn validate(self: *const Self, nodes: []const ir.Node) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const allocator = empty.allocator();
    var input_nodes: usize = 0;

    for (nodes, 0..) |*node, index| {
        const row = project(node);

        if (!(check.executeValue(allocator, &.{ .graph = &self.graph, .index = index, .node = &row }) catch unreachable)) return false;

        input_nodes += @intFromBool(row.kind == .Input);
    }

    return endpoints.executeValue(allocator, &.{ .graph = &self.graph, .input_nodes = input_nodes }) catch unreachable;
}

pub fn project(node: *const ir.Node) Node {
    var row = Node{
        .width = node.sort.width,
        .boolean = node.sort.boolean,
        .kind = undefined,
        .first = 0,
        .second = 0,
        .third = 0,
        .extra = 0,
        .signed = false,
        .family = .Logical,
        .rendering = .Plain,
        .token = "",
    };

    switch (node.value) {
        .input => |i| {
            row.kind = .Input;
            row.first = i;
        },
        .constant => |value| {
            row.kind = .Constant;
            row.first = value;
        },
        .invert => |id| {
            row.kind = .Invert;
            row.first = @backingInt(id);
        },
        .negate => |id| {
            row.kind = .Negate;
            row.first = @backingInt(id);
        },
        .extend => |extension| {
            row.kind = .Extend;
            row.first = @backingInt(extension.operand);
            row.extra = extension.extra;
            row.signed = extension.signed;
        },
        .select => |selection| {
            row.kind = .Select;
            row.first = @backingInt(selection.condition);
            row.second = @backingInt(selection.yes);
            row.third = @backingInt(selection.no);
        },
        .binary => |operation| {
            const traits = binary.traits(operation.operator);

            row.kind = .Binary;
            row.first = @backingInt(operation.left);
            row.second = @backingInt(operation.right);
            row.family = traits.family;
            row.rendering = traits.rendering;
            row.token = traits.token;
        },
    }

    return row;
}
