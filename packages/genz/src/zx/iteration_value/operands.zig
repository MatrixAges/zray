const std = @import("std");
const ir = @import("zx").ir;
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const publication = @import("../construction/publication.zig");
const entry = @import("generated_lower_iteration_elements");
pub const Output = entry.Output;

pub fn lower(context: *Context, allocator: std.mem.Allocator, operands: []const ir.ExprId, fields: ?[]const u32, observe: bool) Lower.Error!Output {
    const lowering = context.lowering;
    var origin: publication.OriginBuffer = undefined;

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .origin = @ptrCast(&origin),
        .context = @ptrCast(context),
        .operands = @ptrCast(operands),
        .fields = fields,
        .observe = observe,
    };

    return entry.executeIn(allocator, &input) catch |err| return publication.failure(err);
}

pub fn observeIterationOperand(handle: *anyopaque, item: u32, reference: u32) Lower.Error!u64 {
    const context: *Context = @ptrCast(@alignCast(handle));

    return context.cache.observe(context.lowering.allocator, @fromBackingInt(item), @fromBackingInt(reference), null, &context.reads);
}
