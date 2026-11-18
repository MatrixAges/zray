const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Slots = @import("../slots.zig");
const generated = @import("generated_uniqueness_flow_facts");
const Input = std.meta.Child(generated.Input);
const Facts = std.meta.Child(generated.Output);
const Self = @This();

seen: []const bool,
definitions: std.meta.Child(@FieldType(Facts, "definitions")),
results: []const u32,
prepared: std.meta.Child(@FieldType(Facts, "prepared")),
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
pub fn keep(owner: std.mem.Allocator, temporary: std.mem.Allocator, function: *const ir.Function, slots: Slots) std.mem.Allocator.Error!Self {
    const order = source(std.meta.Child(@FieldType(Input, "source")), function);
    const input: Input = .{ .source = &order, .counts = slots.counts };

    const facts = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .seen = try owner.dupe(bool, facts.seen),
        .definitions = try zx.columns.copyScalarColumns(owner, facts.definitions),
        .results = try owner.dupe(u32, facts.results),
        .prepared = try zx.columns.copyScalarColumns(owner, facts.prepared),
    };
}

pub fn view(self: *const Self) Facts {
    return .{ .seen = self.seen, .definitions = &self.definitions, .results = self.results, .prepared = &self.prepared };
}
