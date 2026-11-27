const std = @import("std");
const ir = @import("zx").ir;
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const publication = @import("../construction/publication.zig");
const entry = @import("generated_lower_iteration_elements");
const Bindings = @import("literals.zig").Bindings;
pub const Observation = struct { context: *Context, counts: []u64 };

const Frame = struct {
    lowering: *Lower,
    observation: ?Observation,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(lowering: *Lower, allocator: std.mem.Allocator, bindings: Bindings, operands: []const ir.ExprId, fields: ?[]const u32, observation: ?Observation) Lower.Error![]const u32 {
    var origin: publication.OriginBuffer = undefined;
    var frame: Frame = .{ .lowering = lowering, .observation = observation };

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .origin = @ptrCast(&origin),
        .batch = @ptrCast(&frame),
        .operands = @ptrCast(operands),
        .fields = fields,
        .observe = observation != null,
    };

    const output = entry.executeIn(allocator, &input) catch |err| return publication.failure(err);

    @memcpy(bindings.names, output.names);
    @memcpy(bindings.values, output.values);
    @memcpy(bindings.references, output.references);

    return output.field_values;
}

pub fn publishIterationOperand(handle: *anyopaque, index: u64, item: u32, reference: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const source = frame.observation.?;
    const context = source.context;

    source.counts[@intCast(index)] = try context.cache.observe(frame.lowering.allocator, @fromBackingInt(item), @fromBackingInt(reference), null, &context.reads);
}
