const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Operand = @import("operand.zig");
const entry = @import("generated_lower_iteration_elements");
const Bindings = @import("literals.zig").Bindings;
pub const Observation = struct { context: *Context, counts: []u64 };

const Frame = struct {
    lowering: *Lower,
    allocator: std.mem.Allocator,
    bindings: Bindings,
    observation: ?Observation,
    values: []u32 = &.{},
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(lowering: *Lower, allocator: std.mem.Allocator, bindings: Bindings, operands: []const ir.ExprId, fields: ?[]const u32, observation: ?Observation) Lower.Error![]const u32 {
    var frame: Frame = .{ .lowering = lowering, .allocator = allocator, .bindings = bindings, .observation = observation };

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(lowering),
        .batch = @ptrCast(&frame),
        .operands = @ptrCast(operands),
        .fields = fields,
    };

    try evaluation.execute(entry, &input);

    return frame.values;
}

pub fn publishIterationOperand(handle: *const anyopaque, index: u64, item: u32, value: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const operand = try Operand.bind(frame.lowering, @fromBackingInt(value));
    const ordinal: usize = @intCast(index);

    frame.bindings.set(ordinal, operand);

    if (frame.observation) |source| {
        const context = source.context;
        source.counts[ordinal] = try context.cache.observe(frame.lowering.allocator, @fromBackingInt(item), operand.reference, null, &context.reads);
    }
}

pub fn prepareIterationFields(handle: *const anyopaque, length: u64) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.values = try frame.allocator.alloc(u32, @intCast(length));
}

pub fn publishIterationField(handle: *const anyopaque, index: u64, value: u32) void {
    Frame.borrow(handle).values[@intCast(index)] = value;
}
