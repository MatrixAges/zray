const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Slots = @import("../slots.zig");
const generated = @import("generated_uniqueness_flow_facts");
const saving = @import("generated_uniqueness_flow_save_facts");
const Input = std.meta.Child(generated.Input);
pub const Facts = std.meta.Child(saving.Output);

pub fn source(comptime Target: type, function: *const ir.Function) Target {
    const block = function.body.block();

    return .{
        .expressions = zx.columns.pointer(@FieldType(Target, "expressions"), &function.expressions),
        .control = zx.columns.pointer(@FieldType(Target, "control"), block.control),
        .symbols = function.symbols.count(),
        .first = @intCast(block.first),
        .count = @intCast(block.len),
    };
}

/// A worklist can revisit a function after its preparation arena has been reset.
pub fn keep(owner: std.mem.Allocator, temporary: std.mem.Allocator, function: *const ir.Function, slots: Slots) std.mem.Allocator.Error!*const Facts {
    const order = source(std.meta.Child(@FieldType(Input, "source")), function);
    const input: Input = .{ .source = &order, .counts = slots.counts };

    const facts = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return saving.executeIn(owner, zx.columns.pointer(saving.Input, facts)) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };
}
