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
const names_entry = @import("generated_scope_reuse_names");
const NamesInput = std.meta.Child(names_entry.Input);
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
    saved: []const []const u8,
    pub fn restore(self: Names, lowering: *Lower) void {
        restoreNames(lowering, self);
    }
};

pub fn saveNames(lowering: *const Lower, symbols: []const ir.SymbolId, allocator: std.mem.Allocator) Lower.Error!Names {
    const ids = view.slice([]const u32, symbols);

    if (ids.len == 0) return .{ .symbols = ids, .saved = &.{} };

    const input: NamesInput = .{
        .symbols = ids,
        .sources = &.{},
        .replacements = &.{},
        .names = lowering.names,
        .saved = &.{},
        .action = .Save,
    };

    const output = names_entry.executeIn(allocator, &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return .{ .symbols = ids, .saved = output.saved };
}

pub fn setNames(lowering: *Lower, symbols: []const u32, replacements: []const []const u8) void {
    applyNames(lowering, symbols, &.{}, replacements, null, .Replace);
}

pub fn bindNames(lowering: *Lower, symbols: []const ir.SymbolId, replacements: []const []const u8, saved: [][]const u8) Names {
    const ids = view.slice([]const u32, symbols);

    applyNames(lowering, ids, &.{}, replacements, saved, .Bind);

    return .{ .symbols = ids, .saved = saved };
}

pub fn restore(self: *const Self, lowering: *Lower) void {
    if (!generated) return self.state.restore(lowering);

    restoreNames(lowering, .{ .symbols = self.state.alias_symbols, .saved = self.state.saved });
}

fn restoreNames(lowering: *Lower, names: Names) void {
    applyNames(lowering, names.symbols, names.saved, &.{}, null, .Restore);
}

pub fn publishSeed(self: *const Self, lowering: *Lower, output: *std.ArrayList(node.Statement), index: usize) Lower.Error!?node.Block {
    if (!(try self.state.append(lowering, output, index))) return null;

    return try lowering.builder.statements(output.items);
}

fn applyNames(
    lowering: *Lower,
    symbols: []const u32,
    saved: []const []const u8,
    replacements: []const []const u8,
    target: ?[][]const u8,
    action: @FieldType(NamesInput, "action"),
) void {
    if (symbols.len == 0) return;

    const input: NamesInput = .{
        .symbols = symbols,
        .sources = &.{},
        .replacements = replacements,
        .names = lowering.names,
        .saved = saved,
        .action = action,
    };

    var buffer: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(lowering.workspace);

    defer arena.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const output = names_entry.executeIn(scratch.allocator(), &input) catch unreachable;

    for (output.updates) |update| {
        lowering.names[@intCast(update.symbol)] = update.name;
    }

    if (target) |destination| @memcpy(destination, output.saved);
}
