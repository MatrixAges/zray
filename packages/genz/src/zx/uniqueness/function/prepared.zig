const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Slots = @import("../slots.zig");
const Summaries = @import("../summaries.zig");
const generated = @import("generated_uniqueness_function_prepare");
const publishing = @import("generated_uniqueness_function_publish");
const Input = std.meta.Child(generated.Input);
pub const Facts = std.meta.Child(publishing.Output);

pub fn build(owner: std.mem.Allocator, workspace: std.mem.Allocator, unit: *const Function.Unit, block: zx.ir.Block, slots: Slots, summaries: *const Summaries) std.mem.Allocator.Error!*const Facts {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const Source = std.meta.Child(@FieldType(Input, "source"));

    const source: Source = .{
        .expressions = zx.columns.pointer(@FieldType(Source, "expressions"), unit.expressions),
        .control = zx.columns.pointer(@FieldType(Source, "control"), block.control),
        .symbols = unit.symbols.count(),
        .first = @intCast(block.first),
        .count = @intCast(block.len),
    };

    const input: Input = .{
        .source = &source,
        .symbols = unit.symbols.types,
        .counts = slots.counts,
        .layout = &.{ .offsets = slots.offsets, .members = @ptrCast(slots.members), .unwrapped = @ptrCast(slots.unwrapped) },
        .held = summaries.held,
        .written = summaries.written,
        .effects = summaries.effects,
    };

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return publishing.executeIn(owner, zx.columns.pointer(publishing.Input, output)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
