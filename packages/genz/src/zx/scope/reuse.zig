const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const Self = @This();
const generated = @import("genz_options").generated_analysis;
const Seed = @import("reuse/seed.zig");
const entry = @import("generated_scope_reuse");
const Input = std.meta.Child(entry.Input);
const Plan = std.meta.Child(std.meta.Child(entry.Output));

const Active = struct {
    candidates: @FieldType(Plan, "candidates"),
    changes: []const ?u32,
    alias_symbols: []const u32,
    saved: []const []const u8,
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

    const input: Input = .{
        .matching = &matching,
        .bindings = scope.bindings.values,
        .symbols = scope.bindings.symbols,
        .result = @backingInt(scope.result),
        .names = lowering.names,
    };

    const result = entry.executeIn(scratch, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const plan = result orelse return null;

    for (plan.updates) |update| {
        lowering.names[@intCast(update.symbol)] = update.name;
    }

    const state: Active = .{
        .candidates = plan.candidates,
        .changes = plan.changes,
        .alias_symbols = plan.alias_symbols,
        .saved = plan.saved,
    };

    return .{ .variables = plan.variables, .state = state };
}

pub const Names = struct {
    symbols: []const u32,
    saved: [][]const u8,
    pub fn restore(self: Names, lowering: *Lower) void {
        applyNames(lowering, self.symbols, self.saved, &.{}, true);
    }
};

pub fn bindNames(lowering: *Lower, symbols: []const ir.SymbolId, replacements: []const []const u8, saved: [][]const u8) Names {
    applyNames(lowering, view.slice([]const u32, symbols), saved, replacements, false);

    return .{ .symbols = view.slice([]const u32, symbols), .saved = saved };
}

pub fn restore(self: *const Self, lowering: *Lower) void {
    if (!generated) return self.state.restore(lowering);

    applyNames(lowering, self.state.alias_symbols, self.state.saved, &.{}, true);
}

pub fn publishSeed(self: *const Self, lowering: *Lower, output: *std.ArrayList(node.Statement), index: usize) Lower.Error!?node.Block {
    if (!(try self.state.append(lowering, output, index))) return null;

    return try lowering.builder.statements(output.items);
}

fn applyNames(lowering: *Lower, symbols: []const u32, saved: anytype, replacements: []const []const u8, comptime restoring: bool) void {
    if (symbols.len == 0) return;

    const install = @import("generated_scope_reuse_names");

    const input: std.meta.Child(install.Input) = .{
        .symbols = symbols,
        .sources = &.{},
        .replacements = replacements,
        .names = lowering.names,
        .saved = saved,
        .restore = restoring,
    };

    var buffer: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(lowering.workspace);

    defer arena.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const output = install.executeIn(scratch.allocator(), &input) catch unreachable;

    for (output.updates) |update| {
        lowering.names[@intCast(update.symbol)] = update.name;
    }

    if (!restoring) {
        @memcpy(saved, output.saved);
    }
}
