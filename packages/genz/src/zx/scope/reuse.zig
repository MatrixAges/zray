const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const Self = @This();
const Change = @import("../object_update.zig").Change;
const generated = @import("genz_options").generated_analysis;
const Seed = @import("reuse/seed.zig");
const entry = @import("generated_scope_reuse");
const Input = std.meta.Child(entry.Input);
const Plan = std.meta.Child(std.meta.Child(entry.Output));

const Active = struct {
    candidates: @FieldType(Plan, "candidates"),
    changes: []const ?u32,
    alias_symbols: []const u32,
    saved: [][]const u8,
};

variables: []const bool,
state: if (generated) Active else Seed,
pub fn create(lowering: *Lower, scope: ir.ScopeRow, scratch: std.mem.Allocator) Lower.Error!?Self {
    if (!generated) {
        const plan = (try Seed.create(lowering, scope)) orelse return null;

        return .{ .variables = plan.variables, .state = plan };
    }

    const enabled = @import("generated_scope_reuse_enabled");
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const flags: std.meta.Child(enabled.Input) = .{
        .state_active = lowering.state_active,
        .bindings = scope.bindings.len,
        .iteration = lowering.iteration_value != null,
        .loop_fields = lowering.loop_fields != null,
    };

    if (!(enabled.executeIn(fixed.allocator(), &flags) catch unreachable)) return null;

    var storage: @import("../object_update/matching.zig").Borrow = undefined;
    const matching = storage.view(lowering);
    var saved: [][]const u8 = &.{};

    const input: Input = .{
        .matching = &matching,
        .bindings = scope.bindings.values,
        .symbols = scope.bindings.symbols,
        .result = @backingInt(scope.result),
        .names = @ptrCast(&lowering.names),
        .saved = @ptrCast(&saved),
    };

    const result = entry.executeIn(scratch, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const plan = result orelse return null;

    const state: Active = .{
        .candidates = plan.candidates,
        .changes = plan.changes,
        .alias_symbols = plan.alias_symbols,
        .saved = saved,
    };

    return .{ .variables = plan.variables, .state = state };
}

pub fn restore(self: *const Self, lowering: *Lower) void {
    if (!generated) return self.state.restore(lowering);

    const saved: Names = .{ .symbols = self.state.alias_symbols, .saved = self.state.saved };

    saved.restore(lowering);
}

pub fn publish(self: *const Self, lowering: *Lower, index: usize) Lower.Error!?node.Block {
    const row = self.state.changes[index] orelse return null;
    const facts = self.state.candidates;

    const change: Change = .{
        .previous = @fromBackingInt(facts.previous[row]),
        .reference = @fromBackingInt(facts.references[row]),
        .field = .{ .index = facts.field_indices[row], .value = @fromBackingInt(facts.field_values[row]) },
        .type_id = @fromBackingInt(facts.types[row]),
    };

    return try @import("../object_update/emit.zig").statementBlock(lowering, change);
}

pub fn publishSeed(self: *const Self, lowering: *Lower, output: *std.ArrayList(node.Statement), index: usize) Lower.Error!?node.Block {
    if (!(try self.state.append(lowering, output, index))) return null;

    return try lowering.builder.statements(output.items);
}

pub const Names = struct {
    symbols: []const u32,
    saved: [][]const u8,
    pub fn restore(self: Names, lowering: *Lower) void {
        applyNames(lowering, self, &.{}, true);
    }
};

pub fn bindNames(lowering: *Lower, symbols: []const ir.SymbolId, replacements: []const []const u8, saved: [][]const u8) Names {
    const binding: Names = .{ .symbols = view.slice([]const u32, symbols), .saved = saved };

    applyNames(lowering, binding, replacements, false);

    return binding;
}

fn applyNames(lowering: *Lower, binding_arg: Names, replacements: []const []const u8, restoring: bool) void {
    var binding = binding_arg;

    if (binding.symbols.len == 0) return;

    const install = @import("generated_scope_reuse_names");

    const input: std.meta.Child(install.Input) = .{
        .symbols = binding.symbols,
        .sources = &.{},
        .replacements = replacements,
        .names = @ptrCast(&lowering.names),
        .saved = @ptrCast(&binding.saved),
        .restore = restoring,
    };

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    install.executeIn(memory.allocator(), &input) catch unreachable;
}
