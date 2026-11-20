const std = @import("std");
const ir = @import("zx").ir;
pub const Uniqueness = @import("uniqueness/root.zig");
const Self = @This();

pub const Entry = @import("entry_flags.zig");

value: @import("value_call/analysis.zig").Summary,
entry_flags: Entry.Flags,
io: []const bool,
process: []const bool,
/// Functions that start tasks, themselves or through their callees.
tasks: []const bool,
/// The errors each function raises, null where unknown.
errors: []const ?[]const []const u8 = &.{},
return_allocations: []const bool,
layout_types: []const @import("iteration_layout/generated.zig").Type = &.{},
/// The pure functions that compare no represented aggregates by identity, themselves or through their callees.
identity_free: []const bool = &.{},
/// The functions whose output holds no part of their input.
fresh_outputs: []const bool = &.{},
constructed_outputs: []const bool = &.{},
grows: []const bool = &.{},
uniqueness: Uniqueness.Result,
basis: *const Uniqueness.Basis,
/// Replaces the entry plan for a body sharing the types and functions of the original analysis.
pub fn reentry(self: *Self, allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program) std.mem.Allocator.Error!void {
    self.entry_flags = try Entry.analyze(workspace, program, .{ .local = self.value.local, .pure = self.value.pure, .io = self.io, .process = self.process, .tasks = self.tasks });
    self.uniqueness.entry = try Uniqueness.analyzeEntry(allocator, workspace, program, self.basis);
}

pub fn hasValueEntry(self: Self) bool {
    return self.entry_flags.value;
}

pub fn hasStateEntry(self: Self, program: ir.Program) bool {
    if (!@import("genz_options").generated_analysis) return !program.type_only and self.entry_flags.value and !self.entry_flags.tasks and
        (self.value.state.represented(program, program.output_type) or self.value.state.represented(program, program.input_type) or self.value.state.inlineRows(program, program.input_type));

    return @import("entry/policy.zig").select(.{
        .tasks = self.entry_flags.tasks,
        .enabled = self.entry_flags.value,
        .type_only = program.type_only,
        .represented_input = self.value.state.represented(program, program.input_type) or self.value.state.inlineRows(program, program.input_type),
        .represented_output = self.value.state.represented(program, program.output_type),
        .output_kind = @fromBackingInt(@intCast(program.types.kinds[@backingInt(program.output_type)])),
    }).state;
}

/// Whether the entry of `program` has `executeIn`: a body that starts tasks shares its allocator between threads, so
/// it runs in the arena `execute` lends alone.
pub fn hasAllocatorEntry(self: Self) bool {
    if (!@import("genz_options").generated_analysis) return !self.entry_flags.tasks;

    return @import("entry/policy.zig").allocator(self.entry_flags.tasks);
}

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Self,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn create(backing: std.mem.Allocator, program: ir.Program) std.mem.Allocator.Error!Owned {
    return createExported(backing, program, &.{});
}

/// Facts for a program whose `exported` functions the host also calls directly.
pub fn createExported(backing: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId) std.mem.Allocator.Error!Owned {
    return createRemembered(backing, program, exported, null);
}

/// Facts that also reuse and extend the body analyses `memo` remembers from earlier programs.
pub fn createRemembered(backing: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, memo: ?*Uniqueness.Memo) std.mem.Allocator.Error!Owned {
    return createWithConcurrency(backing, program, exported, memo, false);
}

/// `backing` and every allocator behind `memo` must be threadsafe; this call exclusively borrows `memo`.
pub fn createRememberedConcurrent(backing: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, memo: ?*Uniqueness.Memo) std.mem.Allocator.Error!Owned {
    return createWithConcurrency(backing, program, exported, memo, true);
}

fn createWithConcurrency(backing: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, memo: ?*Uniqueness.Memo, comptime concurrent: bool) std.mem.Allocator.Error!Owned {
    var arena = std.heap.ArenaAllocator.init(backing);

    errdefer arena.deinit();

    const owned = arena.allocator();
    const basis = try owned.create(Uniqueness.Basis);
    const value = try analyzeFrom(owned, backing, program, exported, .{ .build = basis }, memo, concurrent);

    return .{ .arena = arena, .value = value };
}

pub fn analyze(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Uniqueness.Basis, memo: ?*Uniqueness.Memo) std.mem.Allocator.Error!Self {
    return analyzeFrom(allocator, workspace, program, exported, .{ .ready = basis }, memo, false);
}

/// All allocators must be threadsafe, including shared parents and those behind the exclusively borrowed `memo`.
pub fn analyzeConcurrent(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, basis: *const Uniqueness.Basis, memo: ?*Uniqueness.Memo) std.mem.Allocator.Error!Self {
    return analyzeFrom(allocator, workspace, program, exported, .{ .ready = basis }, memo, true);
}

/// The basis uniqueness reads, or where to build it alongside function facts.
const Source = union(enum) {
    ready: *const Uniqueness.Basis,
    build: *Uniqueness.Basis,
    fn basis(self: Source) *const Uniqueness.Basis {
        return switch (self) {
            .ready => |value| value,
            .build => |value| value,
        };
    }
};

fn analyzeFrom(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId, source: Source, memo: ?*Uniqueness.Memo, comptime concurrent: bool) std.mem.Allocator.Error!Self {
    var building = BasisBuild{ .allocator = allocator, .workspace = workspace, .program = program, .source = source, .memo = memo };
    const thread: ?std.Thread = if (concurrent and source == .build) std.Thread.spawn(.{}, BasisBuild.run, .{&building}) catch null else null;

    if (thread == null) building.run();

    const others = remaining(allocator, workspace, program, exported);

    if (thread) |running| running.join();

    var value = try others;

    try building.result;

    value.basis = source.basis();

    value.uniqueness = if (concurrent)
        try Uniqueness.analyzeConcurrent(allocator, workspace, program, exported, value.basis, value.return_allocations, memo)

    else
        try Uniqueness.analyze(allocator, workspace, program, exported, value.basis, value.return_allocations, memo);

    value.entry_flags = try Entry.analyze(workspace, program, .{ .local = value.value.local, .pure = value.value.pure, .io = value.io, .process = value.process, .tasks = value.tasks });

    return value;
}

/// Each function's output holds no part of its input when the input is no descendant of it; every function walks the
/// types under its output once, marking them with its own round.
fn freshOutputs(allocator: std.mem.Allocator, program: ir.Program) std.mem.Allocator.Error![]const bool {
    const result = try allocator.alloc(bool, program.functions.count());
    const seen = try allocator.alloc(u32, program.types.count());
    var pending: std.ArrayList(ir.TypeId) = .empty;

    defer allocator.free(seen);
    defer pending.deinit(allocator);
    @memset(seen, 0);

    for (result, 1..) |*fresh, round| {
        const function = program.functions.at(round - 1);

        pending.clearRetainingCapacity();

        try children(allocator, program, function.output_type, &pending);

        fresh.* = while (pending.pop()) |id| {
            if (id == function.input_type) break false;
            if (seen[@backingInt(id)] == round) continue;

            seen[@backingInt(id)] = @intCast(round);

            try children(allocator, program, id, &pending);
        } else true;
    }

    return result;
}

fn children(allocator: std.mem.Allocator, program: ir.Program, id: ir.TypeId, pending: *std.ArrayList(ir.TypeId)) std.mem.Allocator.Error!void {
    switch (program.typeOf(id)) {
        .optional, .list => |child| try pending.append(allocator, child),
        .tuple => |items| for (0..items.len) |index| try pending.append(allocator, items.at(index)),
        .object => |fields| for (0..fields.len) |index| try pending.append(allocator, fields.at(index).type_id),
        else => {},
    }
}

/// Every fact but the uniqueness plans.
fn remaining(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId) std.mem.Allocator.Error!Self {
    if (@import("genz_options").generated_analysis) {
        const generated = try @import("function_analysis/generated.zig").analyze(allocator, workspace, program, exported);

        return .{
            .value = generated.value,
            .io = generated.io,
            .process = generated.process,
            .tasks = generated.tasks,
            .grows = generated.grows,
            .fresh_outputs = generated.fresh_outputs,
            .constructed_outputs = generated.constructed_outputs,
            .identity_free = generated.identity_free,
            .errors = generated.errors,
            .return_allocations = generated.return_allocations,
            .layout_types = generated.layout_types,
            .entry_flags = undefined,
            .uniqueness = undefined,
            .basis = undefined,
        };
    }

    const value = try @import("value_call/analysis.zig").analyzeExported(allocator, program, exported);
    const errors = try @import("zx").error_effects.perFunction(allocator, program.types, program.functions);
    const return_allocations = try allocator.alloc(bool, errors.len);

    for (return_allocations, program.functions.native_modules, errors) |*allowed, native, names| {
        allowed.* = native == null and @import("functions/policy.zig").allowsAllocation(names);
    }

    return .{
        .value = value,
        .io = try @import("io.zig").functions(allocator, program),
        .process = try @import("capabilities.zig").functions(allocator, program, .process),
        .tasks = try @import("tasks/allocator.zig").functions(allocator, program),
        .fresh_outputs = try freshOutputs(allocator, program),
        .constructed_outputs = try @import("value_call/fresh.zig").functions(allocator, program),
        .identity_free = try @import("iteration_layout/identity_free.zig").functions(allocator, program, value.pure),
        .errors = errors,
        .return_allocations = return_allocations,
        .entry_flags = undefined,
        .uniqueness = undefined,
        .basis = undefined,
    };
}

const BasisBuild = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    program: ir.Program,
    source: Source,
    memo: ?*Uniqueness.Memo,
    result: std.mem.Allocator.Error!void = error.OutOfMemory,
    fn run(self: *BasisBuild) void {
        self.result = switch (self.source) {
            .ready => {},
            .build => |basis| init(self, basis),
        };
    }
    fn init(self: *BasisBuild, basis: *Uniqueness.Basis) std.mem.Allocator.Error!void {
        basis.* = try Uniqueness.Basis.create(self.allocator, self.workspace, self.program, self.memo);
    }
};
