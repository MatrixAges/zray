const std = @import("std");
const zx = @import("zx");
const ir = @import("../ir.zig");
const Value = @import("../../../verification/terms.zig").Value;
const Conditions = @import("../../../verification/conditions.zig");
const source = @import("generated_build_hardware_graph");
const limits = @import("generated_hardware_limits").@"zx.constants";
const Circuit = @import("../graph/circuit.zig");
const node = @import("../graph/node.zig");
const Error = std.mem.Allocator.Error || error{InvalidHardwareTerm};

pub fn build(comptime Graph: type, allocator: std.mem.Allocator, scratch: std.mem.Allocator, program: zx.ir.Program, model: Conditions.Model) Error!Graph {
    const Input = std.meta.Child(source.Input);
    const Table = std.meta.Child(@FieldType(Input, "types"));
    const program_types: *const zx.ir.TypeTable = &program.types;
    const types = zx.columns.borrow(Table, program_types);
    const rows = model.definitions;
    const origins = rows.items(.origin);
    const input_types = zx.memory.borrowReadColumn(zx.ir.TypeId, "type_id", model.inputs);
    const input_names = zx.memory.borrowTextColumn("symbol", model.inputs);
    const definition_files = zx.memory.borrowTextColumn("file_name", origins);

    const input: Input = .{
        .types = &types,
        .inputs = model.inputs.len,
        .input_types = @ptrCast(&input_types),
        .input_names = @ptrCast(&input_names),
        .definitions = rows.len,
        .rows = &.{
            .names = rows.items(.name),
            .expressions = rows.items(.expression),
            .widths = rows.items(.width),
            .files = @ptrCast(&definition_files),
        },
        .output_path = limits.output_path,
        .output_type = @backingInt(program.output_type),
        .output = std.mem.asBytes(&model.output.value),
        .value_layout = &Value.layout(std.meta.Child(@FieldType(Input, "value_layout"))),
        .safety = model.output.safe,
    };

    const graph = (source.executeIn(scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds, error.IntegerOverflow, error.Overflow => return error.InvalidHardwareTerm,
        else => unreachable,
    }) orelse return error.InvalidHardwareTerm;

    const Node = if (Graph == Circuit) node.Row else ir.Node;
    const nodes = try allocator.alloc(Node, graph.nodes.len);
    var previous_file: []const u8 = &.{};
    var owned_file: []const u8 = &.{};

    for (graph.nodes, nodes) |row, *result| {
        const origin: ?ir.Origin = if (row.origin) |location| loc: {
            if (previous_file.ptr != location.file.ptr or previous_file.len != location.file.len) {
                owned_file = try allocator.dupe(u8, location.file);
                previous_file = location.file;
            }

            break :loc .{ .file_name = owned_file, .span = origins[@intCast(location.row)].span };
        } else null;

        const value = zx.columns.view(node.Node, row.node);

        result.* = if (Graph == Circuit) .{ .node = value, .origin = origin } else node.legacy(&value, origin);
    }

    const inputs = try allocator.alloc(ir.Port, graph.inputs.len);

    for (graph.inputs, model.inputs, inputs, 0..) |port, original, *result, index| {
        result.* = .{
            .name = original.symbol,
            .path = original.path,
            .sort = .{ .width = port.width, .boolean = port.boolean },
            .signed = port.signed,
            .node = @fromBackingInt(@as(u32, @intCast(index))),
        };
    }

    const outputs = try allocator.alloc(ir.Port, graph.outputs.len);

    for (graph.outputs, outputs) |port, *result| {
        result.* = .{
            .name = try allocator.dupe(u8, port.symbol),
            .path = try allocator.dupe(u8, port.path),
            .sort = .{ .width = @intCast(port.width), .boolean = port.boolean },
            .signed = port.signed,
            .node = @fromBackingInt(port.node),
        };
    }

    return .{
        .nodes = nodes,
        .inputs = inputs,
        .outputs = outputs,
        .safe = @fromBackingInt(graph.safe),
    };
}
