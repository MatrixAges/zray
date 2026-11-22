const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const render = @import("../render.zig").render;
const Lower = @import("lower.zig");
pub const modules = @import("modules.zig");
pub const state = @import("state.zig");
pub const io = @import("io.zig");
pub const value_call = @import("value_call/root.zig");
pub const state_value = @import("state_value/root.zig");
pub const capabilities = @import("capabilities.zig");
pub const tasks = @import("tasks/root.zig");
pub const references = @import("references.zig");
pub const names = @import("names.zig");
pub const partition = @import("partition.zig");
pub const prepare = @import("inline_call/root.zig").prepare;
pub const prepareWithWorkspace = @import("inline_call/root.zig").prepareWithWorkspace;
pub const function_analysis = @import("function_analysis.zig");
pub const constant_namespace = @import("module/constants.zig").namespace;

pub fn emit(allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error![]u8 {
    return emitWithConcurrency(allocator, program, false);
}

/// `allocator` and its parents must be threadsafe.
pub fn emitConcurrent(allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error![]u8 {
    return emitWithConcurrency(allocator, program, true);
}

fn emitWithConcurrency(allocator: std.mem.Allocator, program: zx.ir.Program, comptime concurrent: bool) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    var lower = try initializePreparedWithConcurrency(temporary, allocator, try prepareWithWorkspace(temporary, allocator, program), concurrent);

    return @import("../render.zig").renderStored(allocator, lower.builder.nodes, try lower.declarations());
}

pub fn bundle(allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error!Bundle {
    return bundleWithConcurrency(allocator, program, false);
}

/// `allocator` and its parents must be threadsafe.
pub fn bundleConcurrent(allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error!Bundle {
    return bundleWithConcurrency(allocator, program, true);
}

fn bundleWithConcurrency(allocator: std.mem.Allocator, program: zx.ir.Program, comptime concurrent: bool) std.mem.Allocator.Error!Bundle {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    var lower = try initializePreparedWithConcurrency(temporary, allocator, try prepareWithWorkspace(temporary, allocator, program), concurrent);
    const types = try @import("type_bundle.zig").render(allocator, &lower);

    errdefer allocator.free(types);

    lower.shared_types = true;

    return .{ .source = try @import("../render.zig").renderStored(allocator, lower.builder.nodes, try lower.declarations()), .types = types };
}

pub const Bundle = struct {
    source: []u8,
    types: []u8,
    pub fn deinit(self: Bundle, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.types);
    }
};

/// Workspace backs short-lived analysis storage that is released before the lowering arena.
pub fn initialize(temporary: std.mem.Allocator, workspace: std.mem.Allocator, source: zx.ir.Program) std.mem.Allocator.Error!Lower {
    return initializePrepared(temporary, workspace, try prepareWithWorkspace(temporary, workspace, source));
}

pub fn initializePrepared(temporary: std.mem.Allocator, workspace: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error!Lower {
    return initializePreparedWithConcurrency(temporary, workspace, program, false);
}

fn initializePreparedWithConcurrency(temporary: std.mem.Allocator, workspace: std.mem.Allocator, program: zx.ir.Program, comptime concurrent: bool) std.mem.Allocator.Error!Lower {
    const basis = try temporary.create(Analysis.Uniqueness.Basis);
    basis.* = try .create(temporary, workspace, program, null);

    const facts = if (concurrent)
        try Analysis.analyzeConcurrent(temporary, workspace, program, &.{}, basis, null)
    else
        try Analysis.analyze(temporary, workspace, program, &.{}, basis, null);

    return initializeAnalyzed(temporary, workspace, program, facts, null, !program.type_only);
}

const TypeScratch = @import("types/scratch.zig");
const Analysis = @import("function_analysis.zig");
const generated = @import("genz_options").generated_analysis;
const workspace_entry = if (generated) @import("generated_lowering_workspace") else void;
const WorkspaceStep = if (generated) std.meta.Child(workspace_entry.Output) else enum { Borrow, Ast, Allocate, Bind, Context };

pub fn initializeAnalyzed(temporary: std.mem.Allocator, workspace: std.mem.Allocator, program: zx.ir.Program, facts: Analysis, scratch: ?*TypeScratch, body: bool) std.mem.Allocator.Error!Lower {
    const options = @as(u2, @intFromBool(scratch != null)) << 1 | @intFromBool(body);

    return switch (options) {
        inline else => |form| initializeWorkspace(temporary, workspace, program, facts, scratch, form & 2 != 0, form & 1 != 0),
    };
}

fn initializeWorkspace(temporary: std.mem.Allocator, workspace: std.mem.Allocator, program: zx.ir.Program, facts: Analysis, scratch: ?*TypeScratch, comptime reusable: bool, comptime body: bool) std.mem.Allocator.Error!Lower {
    const count = program.types.count();
    var builder: @import("../builder.zig") = undefined;
    var lowering: Lower = undefined;
    var type_values: []node.ExpressionId = undefined;
    var type_layouts: []node.ExpressionId = undefined;
    var state_types: []node.ExpressionId = &.{};
    var state_layouts: []node.ExpressionId = &.{};
    var views: []node.ExpressionId = &.{};

    inline for (comptime workspaceSteps(reusable, body)) |step| switch (step) {
        .Borrow => {
            const columns = try scratch.?.prepare(count);

            type_values = columns.abi_types;
            type_layouts = columns.abi_layouts;
            state_types = columns.state_types;
            state_layouts = columns.state_layouts;
            views = columns.views;
        },
        .Ast => builder = try @import("../builder.zig").init(temporary),
        .Allocate => {
            if (generated) {
                try @import("types/workspace.zig").allocateAbi(temporary, count, &type_values, &type_layouts);
            } else {
                type_values = try temporary.alloc(node.ExpressionId, count);
                type_layouts = try temporary.alloc(node.ExpressionId, count);
            }
        },
        .Bind => lowering = .{
            .allocator = temporary,
            .workspace = workspace,
            .program = program,
            .entry_flags = facts.entry_flags,
            .builder = builder,
            .types = type_values,
            .layouts = type_layouts,
            .type_scratch = scratch,
            .state_types = state_types,
            .state_layouts = state_layouts,
            .view_types = views,
            .state_plan = facts.value.state,
            .layout_types = facts.layout_types,
            .slot_counts = facts.basis.slots.counts,
            .growth_functions = facts.grows,
            .io_functions = facts.io,
            .process_functions = facts.process,
            .task_functions = facts.tasks,
            .function_errors = if (facts.errors.len == program.functions.count()) facts.errors else null,
            .value_functions = facts.value.values,
            .pure_functions = facts.value.pure,
            .identity_free_functions = facts.identity_free,
            .local_functions = facts.value.local,
            .fresh_outputs = facts.fresh_outputs,
            .constructed_outputs = facts.constructed_outputs,
            .plans = facts.uniqueness.functions,
            .plan = facts.uniqueness.entry,
        },
        .Context => try @import("functions/context.zig").reserve(&lowering),
    };

    return lowering;
}

fn workspaceSteps(comptime reusable: bool, comptime body: bool) []const WorkspaceStep {
    if (generated) return zx.staticSequence(workspace_entry, &.{ .reusable = reusable, .body = body });

    const setup: []const WorkspaceStep = if (reusable) &.{ .Borrow, .Ast } else &.{ .Ast, .Allocate };
    const finish: []const WorkspaceStep = if (body) &.{ .Bind, .Context } else &.{.Bind};

    return setup ++ finish;
}
