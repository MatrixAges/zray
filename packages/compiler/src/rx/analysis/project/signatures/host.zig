const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../inference/types.zig");
const Kind = @import("../../inference/nodes.zig").Kind;
const Table = @import("../signatures.zig").Table;
const Input = @import("../workflow/solve/abi.zig").Signatures;
const Columns = std.meta.Child(@FieldType(Input, "columns"));
const Nodes = std.meta.Child(@FieldType(Columns, "nodes"));

pub const Frame = struct {
    table: Table = .{},
    input: Input = undefined,
    columns: Columns = undefined,
    nodes: Nodes = undefined,
    ports: std.meta.Child(@FieldType(Columns, "ports")) = undefined,
    target: std.meta.Child(@FieldType(Columns, "target")) = undefined,
    parents: []u32 = undefined,
    pub fn bind(self: *Frame, graph: *const Graph, table: Table, resolver: @FieldType(Input, "resolver")) void {
        const rows = graph.nodes.slice();
        const kinds: []const Kind = rows.items(.kind);
        self.table = table;
        self.parents = graph.parents();

        self.nodes = .{
            .parents = @ptrCast(&self.parents),
            .kinds = zx.columns.slice(@FieldType(Nodes, "kinds"), kinds),
            .arguments = rows.items(.argument),
        };

        self.ports = .{
            .inputs = table.inputs,
            .outputs = table.outputs,
            .binding_ends = table.binding_ends,
            .task_ends = table.task_ends,
        };

        self.target = .{
            .bindings = @ptrCast(&self.table.binding_types),
            .tasks = @ptrCast(&self.table.task_types),
            .inputs = @ptrCast(&self.table.inputs),
            .outputs = @ptrCast(&self.table.outputs),
        };

        self.columns = .{ .nodes = &self.nodes, .ports = &self.ports, .target = &self.target };
        self.input = .{ .resolver = resolver, .columns = &self.columns };
    }
};
