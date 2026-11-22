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
    term_offset: u64 = 0,
    fn borrow(handle: *const anyopaque) *@This() {
        // The handle is read-only. Its stored pointer refers to mutable graph state.
        const reference: *const *@This() = @ptrCast(@alignCast(handle));

        return reference.*;
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
    const reference = &frame;

    const input: Input = .{
        .build = @ptrCast(&reference),
        .types = &types,
        .inputs = model.inputs.len,
        .definitions = rows.len,
        .rows = &.{
            .names = rows.items(.name),
            .expressions = rows.items(.expression),
            .widths = rows.items(.width),
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

pub fn reserveHardwareVariables(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const terms = &Frame.borrow(handle).terms;

    try terms.variables.ensureTotalCapacity(terms.scratch, @intCast(count));
}

pub fn reserveHardwareCache(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const terms = &Frame.borrow(handle).terms;

    try terms.cache.ensureTotalCapacity(terms.scratch, @intCast(count));
}

pub fn reserveHardwareInputs(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.inputs = try frame.terms.allocator.alloc(ir.Port, @intCast(count));
}

pub fn reserveHardwareNodes(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    switch (frame.nodes) {
        inline else => |*rows| try rows.ensureTotalCapacity(frame.terms.allocator, @intCast(count)),
    }
}

pub fn hardwareInputType(handle: *const anyopaque, row: u64) u32 {
    return @backingInt(Frame.borrow(handle).model.inputs[@intCast(row)].type_id);
}

pub fn writeHardwareInput(handle: *const anyopaque, row: u64, kind: native.Kind, width: u16, boolean: bool, signed: bool) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const index: usize = @intCast(row);
    const input = frame.model.inputs[index];
    const sort: ir.Sort = .{ .width = width, .boolean = boolean };

    const id = try frame.nodes.append(frame.terms.allocator, &.{
        .kind = kind,
        .width = width,
        .boolean = boolean,
        .first = row,
        .second = 0,
        .third = 0,
        .operator = 0,
        .extra = 0,
        .signed = false,
    }, frame.terms.origin);

    frame.inputs[index] = .{ .name = input.symbol, .path = input.path, .sort = sort, .signed = signed, .node = id };
}

pub fn bindHardwareInputs(handle: *const anyopaque) Terms.Error!void {
    const frame = Frame.borrow(handle);

    try bindings.bindInputs(&frame.terms, frame.model.inputs);
}

pub fn hardwareDefinitionFile(handle: *const anyopaque, row: u64) []const u8 {
    return Frame.borrow(handle).model.definitions.items(.origin)[@intCast(row)].file_name;
}

pub fn hardwareOriginFile(handle: *const anyopaque) ?[]const u8 {
    const origin = Frame.borrow(handle).terms.origin orelse return null;

    return origin.file_name;
}

pub fn retainHardwareOrigin(handle: *const anyopaque, file: []const u8) std.mem.Allocator.Error![]const u8 {
    return Frame.borrow(handle).terms.allocator.dupe(u8, file);
}

pub fn setHardwareOrigin(handle: *const anyopaque, file: []const u8, row: u64) void {
    const frame = Frame.borrow(handle);
    const span = frame.model.definitions.items(.origin)[@intCast(row)].span;

    frame.terms.origin = .{ .file_name = file, .span = span };
}

pub fn clearHardwareOrigin(handle: *const anyopaque) void {
    Frame.borrow(handle).terms.origin = null;
}

pub fn hardwareTermOffset(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).term_offset;
}

pub fn setHardwareTermOffset(handle: *const anyopaque, offset: u64) void {
    Frame.borrow(handle).term_offset = offset;
}

pub fn hardwareVariable(handle: *const anyopaque, key: []const u8) Terms.Error!?u32 {
    const terms = &Frame.borrow(handle).terms;

    return (try terms.variables.find(terms.scratch, key)).value;
}

pub fn hardwareCacheKeys(handle: *const anyopaque) []const ?[]const u8 {
    return Frame.borrow(handle).terms.cache.view().keys;
}

pub fn hardwareCacheValues(handle: *const anyopaque) []const u32 {
    return Frame.borrow(handle).terms.cache.view().values;
}

pub fn hardwareCacheFull(handle: *const anyopaque) bool {
    const cache = &Frame.borrow(handle).terms.cache;

    return cache.count == cache.limit;
}

pub fn growHardwareCache(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const terms = &Frame.borrow(handle).terms;

    try terms.cache.ensureTotalCapacity(terms.scratch, terms.cache.count + 1);
}

pub fn hardwareNodeCount(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).nodes.count();
}

pub fn appendHardwareTerm(handle: *const anyopaque, position: u64, key: []const u8, kind: native.Kind, width: u16, boolean: bool, first: u64, second: u32, third: u32, operator: u8, extra: u16, signed: bool) std.mem.Allocator.Error!u32 {
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

pub fn publishHardwareDefinition(handle: *const anyopaque, name: []const u8, width: u16, index: u32) Terms.Error!void {
    const frame = Frame.borrow(handle);

    try bindings.publish(&frame.terms, name, width, @fromBackingInt(index), frame.nodes.sort(index));
}

pub fn hardwareNodeWidth(handle: *const anyopaque, index: u32) u16 {
    return Frame.borrow(handle).nodes.sort(index).width;
}

pub fn hardwareNodeIsBoolean(handle: *const anyopaque, index: u32) bool {
    return Frame.borrow(handle).nodes.sort(index).boolean;
}

pub fn hardwareOutputCount(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).outputs.items.len;
}

pub fn writeHardwareOutput(handle: *const anyopaque, name: []const u8, path: []const u8, index: u32, width: u64, boolean: bool, signed: bool) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    try frame.outputs.append(frame.terms.allocator, .{
        .name = name,
        .path = path,
        .sort = .{ .width = @intCast(width), .boolean = boolean },
        .signed = signed,
        .node = @fromBackingInt(index),
    });
}

pub fn rejectHardwareTerm() error{InvalidHardwareTerm}!void {
    return error.InvalidHardwareTerm;
}
