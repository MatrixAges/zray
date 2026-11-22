const std = @import("std");
const memory = @import("zx").memory;
const ir = @import("../ir.zig");
const binary = @import("../binary.zig");
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
nodes: []const ir.Node,
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
    self.nodes = module.nodes;
}

pub fn scan(self: *const Self) Scan {
    return .{ .graph = &self.graph, .nodes = @ptrCast(&self.nodes) };
}

pub fn validate(self: *const Self) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return validate_graph.executeIn(empty.allocator(), &self.scan()) catch unreachable;
}

pub fn readHardwareGraphNode(handle: *const anyopaque, index: u64) *const native.Node {
    const nodes: *const []const ir.Node = @ptrCast(@alignCast(handle));

    return @ptrCast(&nodes.*[@intCast(index)]);
}

fn node(handle: *const anyopaque) *const ir.Node {
    return @ptrCast(@alignCast(handle));
}

pub fn hardwareGraphNodeKind(handle: *const anyopaque) native.Kind {
    return switch (node(handle).value) {
        .input => .Input,
        .constant => .Constant,
        .invert => .Invert,
        .negate => .Negate,
        .extend => .Extend,
        .select => .Select,
        .binary => .Binary,
    };
}

pub fn hardwareGraphNodeWidth(handle: *const anyopaque) u16 {
    return node(handle).sort.width;
}

pub fn hardwareGraphNodeBoolean(handle: *const anyopaque) bool {
    return node(handle).sort.boolean;
}

pub fn hardwareGraphNodeFirst(handle: *const anyopaque) u64 {
    return switch (node(handle).value) {
        .input => |index| index,
        .constant => |literal| literal,
        .invert, .negate => |operand| @backingInt(operand),
        .extend => |extension| @backingInt(extension.operand),
        .select => |selection| @backingInt(selection.condition),
        .binary => |operation| @backingInt(operation.left),
    };
}

pub fn hardwareGraphNodeSecond(handle: *const anyopaque) u64 {
    return switch (node(handle).value) {
        .select => |selection| @backingInt(selection.yes),
        .binary => |operation| @backingInt(operation.right),
        else => unreachable,
    };
}

pub fn hardwareGraphNodeThird(handle: *const anyopaque) u64 {
    return @backingInt(node(handle).value.select.no);
}

pub fn hardwareGraphNodeExtension(handle: *const anyopaque) u16 {
    return node(handle).value.extend.extra;
}

pub fn hardwareGraphNodeSigned(handle: *const anyopaque) bool {
    return node(handle).value.extend.signed;
}

fn traits(handle: *const anyopaque) binary.Traits {
    return binary.traits(node(handle).value.binary.operator);
}

pub fn hardwareGraphNodeFamily(handle: *const anyopaque) native.Family {
    return @fromBackingInt(@backingInt(traits(handle).family));
}

pub fn hardwareGraphNodeRendering(handle: *const anyopaque) native.Rendering {
    return @fromBackingInt(@backingInt(traits(handle).rendering));
}

pub fn hardwareGraphNodeToken(handle: *const anyopaque) []const u8 {
    return traits(handle).token;
}
