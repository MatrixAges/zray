const std = @import("std");
const zx = @import("zx");
const Terms = @import("../terms.zig");
const ir = @import("../ir.zig");
const Conditions = @import("../../../verification/conditions.zig");
const bindings = @import("bindings.zig");
const source = @import("generated_build_hardware_graph");
const limits = @import("generated_hardware_limits").@"zx.constants";
const native = @import("output_execution_abi").layouts.@"zig:hardware_build_host";

const Frame = struct {
    terms: Terms,
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

pub fn build(allocator: std.mem.Allocator, scratch: std.mem.Allocator, program: zx.ir.Program, model: Conditions.Model) Terms.Error!ir.Module {
    var frame: Frame = .{
        .terms = .{ .allocator = allocator, .scratch = scratch },
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

    return .{ .nodes = frame.terms.nodes.items, .inputs = frame.inputs, .outputs = frame.outputs.items, .safe = @fromBackingInt(safe) };
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
    const terms = &Frame.borrow(handle).terms;

    try terms.nodes.ensureTotalCapacity(terms.allocator, @intCast(count));
}

pub fn hardwareInputType(handle: *const anyopaque, row: u64) u32 {
    return @backingInt(Frame.borrow(handle).model.inputs[@intCast(row)].type_id);
}

pub fn writeHardwareInput(handle: *const anyopaque, row: u64, width: u64, boolean: bool, signed: bool) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const index: usize = @intCast(row);
    const input = frame.model.inputs[index];
    const sort: ir.Sort = .{ .width = @intCast(width), .boolean = boolean };
    const id = try frame.terms.append(.{ .sort = sort, .value = .{ .input = index } });

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
    return Frame.borrow(handle).terms.nodes.items.len;
}

pub fn appendHardwareTerm(handle: *const anyopaque, position: u64, key: []const u8, form: native.Form, width: u64, boolean: bool, first: u64, second: u32, third: u32, operator: ?u8, extra: u64) std.mem.Allocator.Error!u32 {
    const terms = &Frame.borrow(handle).terms;

    const id = try terms.append(.{
        .sort = .{ .width = @intCast(width), .boolean = boolean },
        .value = switch (form) {
            .Constant => .{ .constant = first },
            .Invert => .{ .invert = @fromBackingInt(@as(u32, @intCast(first))) },
            .Negate => .{ .negate = @fromBackingInt(@as(u32, @intCast(first))) },
            .Binary => .{ .binary = .{ .operator = @fromBackingInt(@intCast(operator.?)), .left = @fromBackingInt(@as(u32, @intCast(first))), .right = @fromBackingInt(second) } },
            .Select => .{ .select = .{ .condition = @fromBackingInt(@as(u32, @intCast(first))), .yes = @fromBackingInt(second), .no = @fromBackingInt(third) } },
            .SignExtend, .ZeroExtend => .{ .extend = .{ .operand = @fromBackingInt(@as(u32, @intCast(first))), .extra = @intCast(extra), .signed = form == .SignExtend } },
            else => unreachable,
        },
    });

    terms.cache.fillVacant(@intCast(position), key, id);

    return @backingInt(id);
}

pub fn publishHardwareDefinition(handle: *const anyopaque, name: []const u8, width: u16, node: u32) Terms.Error!void {
    try bindings.publish(&Frame.borrow(handle).terms, name, width, @fromBackingInt(node));
}

pub fn hardwareNodeWidth(handle: *const anyopaque, node: u32) u16 {
    return Frame.borrow(handle).terms.nodes.items[node].sort.width;
}

pub fn hardwareNodeIsBoolean(handle: *const anyopaque, node: u32) bool {
    return Frame.borrow(handle).terms.nodes.items[node].sort.boolean;
}

pub fn hardwareOutputCount(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).outputs.items.len;
}

pub fn writeHardwareOutput(handle: *const anyopaque, name: []const u8, path: []const u8, node: u32, width: u64, boolean: bool, signed: bool) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    try frame.outputs.append(frame.terms.allocator, .{
        .name = name,
        .path = path,
        .sort = .{ .width = @intCast(width), .boolean = boolean },
        .signed = signed,
        .node = @fromBackingInt(node),
    });
}

pub fn rejectHardwareTerm() error{InvalidHardwareTerm}!void {
    return error.InvalidHardwareTerm;
}
