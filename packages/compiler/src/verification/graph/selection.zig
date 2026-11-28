const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const Value = @import("../terms.zig").Value;
const entry = @import("generated_select_symbolic_value");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";
const Source = native.SymbolicValue;
const Target = native.SymbolicTarget;

const Frame = struct {
    graph: *Graph,
    program: *const zx.ir.Program,
    span: zx.Span,
};

pub fn select(graph: *Graph, program: *const zx.ir.Program, type_id: zx.ir.TypeId, condition: []const u8, yes: *const Value, no: *const Value, span: zx.Span) zx.Error!Value {
    const Request = std.meta.Child(entry.Input);
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Request, "types")), program.types);
    const layout = Value.layout(std.meta.Child(@FieldType(Request, "layout")));
    const frame: Frame = .{ .graph = graph, .program = program, .span = span };
    var result: Value = undefined;

    const input: Request = .{
        .graph = @ptrCast(&frame),
        .types = &types,
        .type_id = @backingInt(type_id),
        .condition = condition,
        .yes = std.mem.asBytes(yes),
        .no = std.mem.asBytes(no),
        .layout = &layout,
        .result = @ptrCast(&result),
    };

    const valid = entry.executeIn(graph.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.InvalidSource => return error.InvalidSource,
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!valid) return error.InvalidSource;

    return result;
}

pub fn symbolicText(handle: *const anyopaque) ?[]const u8 {
    return read(handle).scalar;
}

pub fn symbolicFieldCount(handle: *const anyopaque) u64 {
    return read(handle).fields.len;
}

pub fn symbolicField(handle: *const anyopaque, index: u64) *const Source {
    return @ptrCast(&read(handle).fields[@intCast(index)]);
}

pub fn targetSymbolicField(handle: *anyopaque, index: u64) *Target {
    return @ptrCast(&write(handle).fields[@intCast(index)]);
}

pub fn reuseSymbolicFields(target: *anyopaque, source: []const u8) void {
    write(target).* = read(source.ptr).*;
}

pub fn reserveSymbolicFields(graph: *const anyopaque, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    const frame: *const Frame = @ptrCast(@alignCast(graph));
    const fields = try frame.graph.allocator.alloc(Value, @intCast(count));

    write(target).* = .{ .fields = fields };
}

pub fn publishSymbolicText(graph: *const anyopaque, target: *anyopaque, type_id: u32, text: []const u8) zx.Error!void {
    const frame: *const Frame = @ptrCast(@alignCast(graph));

    write(target).* = try frame.graph.retain(frame.program.*, @fromBackingInt(type_id), .{ .scalar = text }, frame.span);
}

fn read(handle: *const anyopaque) *const Value {
    return @ptrCast(@alignCast(handle));
}

fn write(handle: *anyopaque) *Value {
    return @ptrCast(@alignCast(handle));
}
