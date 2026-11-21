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

const Active = struct {
    facts: std.MultiArrayList(Fact).Slice,
    changes: []const ?u32,
    alias_symbols: []const u32,
    alias_sources: []const u32,
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

    const entry = @import("generated_scope_reuse");
    const Input = std.meta.Child(entry.Input);
    const Candidates = std.meta.Child(@FieldType(Input, "candidates"));
    var facts: std.MultiArrayList(Fact) = .empty;

    for (0..scope.bindings.len) |index| {
        const binding = scope.bindings.at(index);

        if (binding.symbol == null) continue;

        if (@import("../object_update.zig").match(lowering, binding.value)) |change| {
            try facts.append(scratch, .{
                .binding = @intCast(index),
                .previous = change.previous,
                .reference = change.reference,
                .field_index = change.field.index,
                .field_value = change.field.value,
                .type_id = change.type_id,
            });
        }
    }

    if (facts.len == 0) return null;

    const candidates: Candidates = .{
        .bindings = facts.items(.binding),
        .previous = view.slice(@FieldType(Candidates, "previous"), facts.items(.previous)),
        .types = view.slice(@FieldType(Candidates, "types"), facts.items(.type_id)),
    };

    const program: *const ir.Program = &lowering.program;

    const input: Input = .{
        .expressions = zx.columns.pointer(@FieldType(Input, "expressions"), &program.expressions),
        .bindings = scope.bindings.values,
        .symbols = scope.bindings.symbols,
        .symbol_types = program.symbols.types,
        .result = @backingInt(scope.result),
        .candidates = &candidates,
    };

    const result = entry.executeIn(scratch, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const plan = result orelse return null;

    if (plan.alias_symbols.len == 0) return null;

    const state: Active = .{
        .facts = facts.slice(),
        .changes = plan.changes,
        .alias_symbols = plan.alias_symbols,
        .alias_sources = plan.alias_sources,
        .saved = try scratch.alloc([]const u8, plan.alias_symbols.len),
    };

    names(lowering, &state, false);

    return .{ .variables = plan.variables, .state = state };
}

pub fn restore(self: *const Self, lowering: *Lower) void {
    if (!generated) return self.state.restore(lowering);

    names(lowering, &self.state, true);
}

pub fn publish(self: *const Self, lowering: *Lower, output: *std.ArrayList(node.Statement), index: usize) Lower.Error!?node.Block {
    if (!generated) {
        if (!(try self.state.append(lowering, output, index))) return null;

        return try lowering.builder.statements(output.items);
    }

    const row = self.state.changes[index] orelse return null;
    const facts = self.state.facts.get(row);

    const change: Change = .{
        .previous = facts.previous,
        .reference = facts.reference,
        .field = .{ .index = facts.field_index, .value = facts.field_value },
        .type_id = facts.type_id,
    };

    return try @import("../object_update/emit.zig").statementBlock(lowering, output.items, change);
}

fn names(lowering: *Lower, state: *const Active, restoring: bool) void {
    const entry = @import("generated_scope_reuse_names");

    const input: std.meta.Child(entry.Input) = .{
        .symbols = state.alias_symbols,
        .sources = state.alias_sources,
        .replacements = &.{},
        .names = @ptrCast(&lowering.names),
        .saved = @ptrCast(&state.saved),
        .restore = restoring,
    };

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(memory.allocator(), &input) catch unreachable;
}

const Fact = struct {
    binding: u32,
    previous: ir.SymbolId,
    reference: ir.ExprId,
    field_index: u32,
    field_value: ir.ExprId,
    type_id: ir.TypeId,
};
