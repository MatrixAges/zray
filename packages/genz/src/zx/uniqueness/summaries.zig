const std = @import("std");
const ir = @import("zx").ir;
const Level = @import("level.zig").Level;
const Basis = @import("basis.zig");
const Self = @This();
const generated_analysis = @import("genz_options").generated_analysis;

/// Per function: what every caller guarantees about each input list slot, what every return guarantees about each
/// output list slot, which input slots the output can hold, and which input slots the function may write in place.
/// `inputs` and `outputs` hold the properties some update downstream of each slot wants, so a growth copy pays off.
input: [][]Level = &.{},
output: [][]Level = &.{},
inputs: [][]Level = &.{},
outputs: [][]Level = &.{},
held: []const []const bool,
written: []const []const bool,
return_only: []const bool,
return_allocations: []const bool = &.{},
effects: Basis.Effects,
storage: if (generated_analysis) ?@import("summaries/storage.zig").Model else void = if (generated_analysis) null else {},
pub fn independent(basis: *const Basis) Self {
    return .{ .held = basis.flow.held, .written = basis.flow.written, .return_only = basis.return_only, .effects = basis.effects };
}

pub fn create(allocator: std.mem.Allocator, program: *const ir.Program, basis: *const Basis, active: []const bool) std.mem.Allocator.Error!Self {
    if (generated_analysis) return @import("summaries/storage.zig").create(allocator, program, basis, active);

    const slots = basis.slots;
    const count = program.functions.count();
    const input = try allocator.alloc([]Level, count);
    const output = try allocator.alloc([]Level, count);
    const inputs = try allocator.alloc([]Level, count);
    const outputs = try allocator.alloc([]Level, count);

    for (0..count) |index| {
        input[index] = try allocator.alloc(Level, slots.count(@fromBackingInt(program.functions.input_types[index])));
        output[index] = try allocator.alloc(Level, slots.count(@fromBackingInt(program.functions.output_types[index])));

        const initial: Level = if (active[index]) .all else .none;

        @memset(input[index], initial);
        @memset(output[index], initial);

        inputs[index] = try allocator.alloc(Level, input[index].len);
        outputs[index] = try allocator.alloc(Level, output[index].len);

        @memset(inputs[index], .none);
        @memset(outputs[index], .none);
    }

    return .{ .input = input, .output = output, .inputs = inputs, .outputs = outputs, .held = basis.flow.held, .written = basis.flow.written, .return_only = basis.return_only, .effects = {}, .storage = {} };
}

pub fn mayHold(self: Self, function: ir.FunctionId, slot: u32) bool {
    const values = self.held[@backingInt(function)];

    return slot >= values.len or values[slot];
}

pub fn mayMutate(self: Self, function: ir.FunctionId, slot: u32) bool {
    const values = self.written[@backingInt(function)];

    return slot >= values.len or values[slot];
}

/// With exclusive access, resets optimistic facts. Inputs stay unknown unless every caller is a known call site.
pub fn reset(self: Self, active: []const bool, known: []const bool) void {
    if (generated_analysis) return @import("summaries/lifecycle.zig").apply(self, .Reset, active, known);

    for (self.input, self.output, known[0..self.input.len], 0..) |input, output, callers, index| {
        const internal = active[index];

        @memset(input, if (internal and callers) .all else .none);
        @memset(output, if (internal) .all else .none);
    }
}

/// Forgets facts when the caller exclusively owns the summaries.
pub fn clear(self: Self) void {
    if (generated_analysis) return @import("summaries/lifecycle.zig").apply(self, .Clear, &.{}, &.{});
    for (self.input) |values| @memset(values, .none);
    for (self.output) |values| @memset(values, .none);
}

/// Forgets demands when the caller exclusively owns the summaries.
pub fn clearWants(self: Self) void {
    if (generated_analysis) return @import("summaries/lifecycle.zig").apply(self, .ClearWants, &.{}, &.{});
    for (self.inputs) |values| @memset(values, .none);
    for (self.outputs) |values| @memset(values, .none);
}
