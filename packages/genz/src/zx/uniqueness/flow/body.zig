const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Slots = @import("../slots.zig");
const generated = @import("generated_uniqueness_flow_facts");
const saving = @import("generated_uniqueness_flow_save_facts");
const Input = std.meta.Child(generated.Input);
pub const Facts = std.meta.Child(saving.Output);

pub const View = struct {
    expressions: *const ir.ExpressionTable,
    block: ir.Block,
    symbols: usize,
    pub fn at(functions: *const ir.FunctionTable, index: u32) View {
        return .{
            .expressions = functions.expressions[index],
            .block = functions.controlAt(index).block(),
            .symbols = functions.symbols[index].count(),
        };
    }
};

pub fn source(comptime Target: type, view: View) Target {
    return .{
        .expressions = zx.columns.pointer(@FieldType(Target, "expressions"), view.expressions),
        .control = zx.columns.pointer(@FieldType(Target, "control"), view.block.control),
        .symbols = view.symbols,
        .first = @intCast(view.block.first),
        .count = @intCast(view.block.len),
    };
}

/// A worklist can revisit a function after its preparation arena has been reset.
pub fn keep(owner: std.mem.Allocator, temporary: std.mem.Allocator, view: View, slots: Slots) std.mem.Allocator.Error!*const Facts {
    const order = source(std.meta.Child(@FieldType(Input, "source")), view);
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
