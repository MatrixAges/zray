const std = @import("std");
const zx = @import("zx");
const Terms = @import("../terms.zig");
const ir = @import("../ir.zig");
const Conditions = @import("../../../verification/conditions.zig");
const bindings = @import("bindings.zig");
const source = @import("generated_build_hardware_graph");
const limits = @import("generated_hardware_limits").@"zx.constants";
const Circuit = @import("../graph/circuit.zig");
const node = @import("../graph/node.zig");
const native = @import("output_execution_abi").layouts.@"zig:hardware_graph_host";

const Frame = struct {
    terms: Terms,
    nodes: Nodes,
    model: Conditions.Model,
    inputs: []ir.Port = undefined,
    outputs: std.ArrayList(ir.Port) = .empty,
    sort_view: native.NodeSort = undefined,
    cache_view: native.CacheView = undefined,
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
};

const Nodes = union(enum) {
    circuit: std.ArrayList(node.Row),
    legacy: std.ArrayList(ir.Node),
    fn count(self: *const Nodes) usize {
        return switch (self.*) {
            inline else => |rows| rows.items.len,
        };
    }
    fn append(self: *Nodes, allocator: std.mem.Allocator, value: *const node.Node, origin: ?ir.Origin) std.mem.Allocator.Error!ir.Id {
        const id: ir.Id = @fromBackingInt(@intCast(self.count()));

        switch (self.*) {
            .circuit => |*rows| try rows.append(allocator, .{ .node = value.*, .origin = origin }),
            .legacy => |*rows| try rows.append(allocator, node.legacy(value, origin)),
        }

        return id;
    }
    fn sort(self: *const Nodes, index: u32) ir.Sort {
        return switch (self.*) {
            .circuit => |rows| .{ .width = rows.items[index].node.width, .boolean = rows.items[index].node.boolean },
            .legacy => |rows| rows.items[index].sort,
        };
    }
};

pub fn build(comptime Graph: type, allocator: std.mem.Allocator, scratch: std.mem.Allocator, program: zx.ir.Program, model: Conditions.Model) Terms.Error!Graph {
    var frame: Frame = .{
        .terms = .{ .allocator = allocator, .scratch = scratch },
        .nodes = if (Graph == Circuit) .{ .circuit = .empty } else .{ .legacy = .empty },
        .model = model,
    };

    defer frame.terms.variables.deinit(scratch);
    defer frame.terms.cache.deinit(scratch);

    const Input = std.meta.Child(source.Input);
    const Table = std.meta.Child(@FieldType(Input, "types"));
    const types = zx.columns.borrow(Table, &program.types);
    const rows = model.definitions;
    const input_types = zx.memory.borrowReadColumn(zx.ir.TypeId, "type_id", model.inputs);
    const definition_files = zx.memory.borrowTextColumn("file_name", rows.items(.origin));

    const input: Input = .{
        .build = @ptrCast(&frame),
        .types = &types,
        .inputs = model.inputs.len,
        .input_types = @ptrCast(&input_types),
        .definitions = rows.len,
        .rows = &.{
            .names = rows.items(.name),
            .expressions = rows.items(.expression),
            .widths = rows.items(.width),
            .files = @ptrCast(&definition_files),
        },
        .output_path = limits.output_path,
        .output_type = @backingInt(program.output_type),
        .output = @ptrCast(&frame.model.output.value),
        .safety = model.output.safe,
    };

    const safe = source.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidHardwareTerm, error.IndexOutOfBounds, error.IntegerOverflow, error.Overflow => return error.InvalidHardwareTerm,
        else => unreachable,
    };

    return .{
        .nodes = if (Graph == Circuit) frame.nodes.circuit.items else frame.nodes.legacy.items,
        .inputs = frame.inputs,
        .outputs = frame.outputs.items,
        .safe = @fromBackingInt(safe),
    };
}

pub fn reserveHardwareGraph(handle: *anyopaque, capacity: *const native.GraphCapacity) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const terms = &frame.terms;

    try terms.variables.ensureTotalCapacity(terms.scratch, @intCast(capacity.symbols));
    try terms.cache.ensureTotalCapacity(terms.scratch, @intCast(capacity.definitions));

    frame.inputs = try terms.allocator.alloc(ir.Port, @intCast(capacity.inputs));

    switch (frame.nodes) {
        inline else => |*rows| try rows.ensureTotalCapacity(terms.allocator, @intCast(capacity.nodes)),
    }
}

pub fn writeHardwareInput(handle: *anyopaque, row: u64, port: ?*const native.InputPort) Terms.Error!void {
    const planned = port orelse return error.InvalidHardwareTerm;
    const frame = Frame.borrow(handle);
    const index: usize = @intCast(row);
    const input = frame.model.inputs[index];
    const sort: ir.Sort = .{ .width = planned.width, .boolean = planned.boolean };

    const id = try frame.nodes.append(frame.terms.allocator, &.{
        .kind = planned.kind,
        .width = planned.width,
        .boolean = planned.boolean,
        .first = row,
        .second = 0,
        .third = 0,
        .operator = 0,
        .extra = 0,
        .signed = false,
    }, frame.terms.origin);

    frame.inputs[index] = .{ .name = input.symbol, .path = input.path, .sort = sort, .signed = planned.signed, .node = id };
}

pub fn bindHardwareInputs(handle: *anyopaque) Terms.Error!void {
    const frame = Frame.borrow(handle);

    try bindings.bindInputs(&frame.terms, frame.model.inputs);
}

pub fn retainHardwareOrigin(handle: *anyopaque, file: []const u8) std.mem.Allocator.Error![]const u8 {
    return Frame.borrow(handle).terms.allocator.dupe(u8, file);
}

pub fn setHardwareOrigin(handle: *anyopaque, file: []const u8, row: u64) void {
    const frame = Frame.borrow(handle);
    const span = frame.model.definitions.items(.origin)[@intCast(row)].span;

    frame.terms.origin = .{ .file_name = file, .span = span };
}

pub fn clearHardwareOrigin(handle: *anyopaque) void {
    Frame.borrow(handle).terms.origin = null;
}

pub fn hardwareVariable(handle: *anyopaque, key: []const u8) Terms.Error!?u32 {
    const terms = &Frame.borrow(handle).terms;

    return (try terms.variables.find(terms.scratch, key)).value;
}

pub fn readHardwareCache(handle: *anyopaque) *const native.CacheView {
    const frame = Frame.borrow(handle);
    const cache = &frame.terms.cache;
    const view = cache.view();

    frame.cache_view = .{
        .keys = view.keys,
        .values = view.values,
        .full = cache.count == cache.limit,
    };

    return &frame.cache_view;
}

pub fn growHardwareCache(handle: *anyopaque) std.mem.Allocator.Error!void {
    const terms = &Frame.borrow(handle).terms;

    try terms.cache.ensureTotalCapacity(terms.scratch, terms.cache.count + 1);
}

pub fn hardwareNodeCount(handle: *anyopaque) u64 {
    return Frame.borrow(handle).nodes.count();
}

pub fn appendHardwareTerm(handle: *anyopaque, position: u64, key: []const u8, kind: native.Kind, width: u16, boolean: bool, first: u64, second: u32, third: u32, operator: u8, extra: u16, signed: bool) std.mem.Allocator.Error!u32 {
    const frame = Frame.borrow(handle);
    const terms = &frame.terms;

    const id = try frame.nodes.append(terms.allocator, &.{
        .kind = kind,
        .width = width,
        .boolean = boolean,
        .first = first,
        .second = second,
        .third = third,
        .operator = operator,
        .extra = extra,
        .signed = signed,
    }, terms.origin);

    terms.cache.fillVacant(@intCast(position), key, id);

    return @backingInt(id);
}

pub fn publishHardwareDefinition(handle: *anyopaque, name: []const u8, width: u16, index: u32) Terms.Error!void {
    const frame = Frame.borrow(handle);

    try bindings.publish(&frame.terms, name, width, @fromBackingInt(index), frame.nodes.sort(index));
}

pub fn readHardwareSort(handle: *anyopaque, index: u32) *const native.NodeSort {
    const frame = Frame.borrow(handle);
    const sort = frame.nodes.sort(index);

    frame.sort_view = .{ .width = sort.width, .boolean = sort.boolean };

    return &frame.sort_view;
}

pub fn writeHardwareOutput(handle: *anyopaque, port: ?*const native.OutputPort) Terms.Error!void {
    const planned = port orelse return error.InvalidHardwareTerm;
    const frame = Frame.borrow(handle);

    try frame.outputs.append(frame.terms.allocator, .{
        .name = planned.symbol,
        .path = planned.path,
        .sort = .{ .width = @intCast(planned.width), .boolean = planned.boolean },
        .signed = planned.signed,
        .node = @fromBackingInt(planned.node),
    });
}

pub fn rejectHardwareTerm() error{InvalidHardwareTerm}!void {
    return error.InvalidHardwareTerm;
}
