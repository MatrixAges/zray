const ir = @import("../ir.zig");
const node = @import("node.zig");
const Self = @This();

nodes: []const node.Row,
inputs: []const ir.Port,
outputs: []const ir.Port,
safe: ir.Id,
const Nodes = struct {
    rows: []const node.Row,
    pub fn jsonStringify(self: Nodes, writer: anytype) !void {
        try writer.beginArray();
        for (self.rows) |*row| try writer.write(node.legacy(&row.node, row.origin));
        try writer.endArray();
    }
};

pub fn jsonStringify(self: Self, writer: anytype) !void {
    try writer.write(.{
        .nodes = Nodes{ .rows = self.nodes },
        .inputs = self.inputs,
        .outputs = self.outputs,
        .safe = self.safe,
    });
}
