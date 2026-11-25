const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("parser_options").generated_parser;
const model = @import("artifact/model.zig");
const Origins = @import("nominal_origins.zig");
const Types = @import("link/types.zig");
const Builder = @import("link/build.zig");
const graph = @import("link/graph.zig");
const result = @import("link/result/host.zig");
pub const Error = Types.Error || Builder.Error || graph.Error;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    nominal_types: Origins.Table,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

const Binding = if (generated) @import("link/artifact/binding/host.zig").Window else void;

const Frame = struct {
    owned: std.heap.ArenaAllocator,
    temporary: std.heap.ArenaAllocator,
    workspace: std.heap.ArenaAllocator,
    modules: []const model.Module,
    entry: []const u8,
    plan: graph.Plan = undefined,
    types: Types = undefined,
    builder: Builder = undefined,
    binding: Binding = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn link(allocator: std.mem.Allocator, modules: []const model.Module, entry: []const u8) Error!Result {
    var frame: Frame = .{
        .owned = .init(allocator),
        .temporary = .init(allocator),
        .workspace = .init(allocator),
        .modules = modules,
        .entry = entry,
    };

    errdefer frame.owned.deinit();
    defer frame.temporary.deinit();
    defer frame.workspace.deinit();

    const program = if (comptime generated) program: {
        const rule = @import("generated_artifact_link_execute");
        const request: rule.Input = @ptrCast(&frame);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        try rule.executeIn(empty.allocator(), request);

        break :program try publish(&frame);
    } else try seed(&frame);

    return .{ .arena = frame.owned, .program = program, .nominal_types = frame.types.origins.items.view() };
}

pub fn orderArtifactLink(handle: *anyopaque) graph.Error!void {
    const frame = Frame.borrow(handle);
    frame.plan = try graph.prepare(frame.temporary.allocator(), frame.modules, frame.entry);
}

pub fn registerArtifactTypes(handle: *anyopaque) Types.Error!void {
    const frame = Frame.borrow(handle);
    const owned = frame.owned.allocator();
    const workspace = frame.workspace.allocator();
    const scratch = frame.temporary.allocator();
    const mappings = try scratch.alloc([]const ir.TypeId, frame.modules.len);
    const ids = try scratch.alloc(?ir.FunctionId, frame.modules.len);

    frame.types = try Types.init(owned);

    @memset(ids, null);

    if (comptime generated) {
        try @import("link/registration/host.zig").register(&frame.types, frame.modules, frame.plan.registration, mappings, scratch, &frame.workspace);
    } else {
        for (frame.plan.registration) |row| {
            const index: usize = @intCast(row);

            mappings[index] = try frame.types.appendTemporary(scratch, workspace, &frame.modules[index]);

            if (!frame.workspace.reset(.retain_capacity)) return error.OutOfMemory;
        }
    }

    frame.builder = .{
        .allocator = owned,
        .temporary = workspace,
        .modules = frame.modules,
        .plan = frame.plan,
        .type_mappings = mappings,
        .module_functions = ids,
    };
}

pub fn openArtifactBinding(handle: *anyopaque) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    try frame.binding.init(&frame.builder, frame.temporary.allocator(), &frame.workspace, &frame.owned);

    return frame.plan.registration.len;
}

pub fn artifactWindowCapacity(handle: *anyopaque) u64 {
    return Frame.borrow(handle).binding.capacity();
}

pub fn bindArtifactWindow(handle: *anyopaque, first: u64, count: u64) Builder.Error!void {
    const frame = Frame.borrow(handle);

    try frame.binding.bind(&frame.builder, @intCast(first), @intCast(count));
}

fn publish(frame: *Frame) model.Error!ir.Program {
    const builder = &frame.builder;
    _ = frame.workspace.reset(.free_all);

    const native_modules = builder.native_modules.view();

    return @import("link/result/publication/host.zig").finish(
        frame.owned.allocator(),
        frame.temporary.allocator(),
        &frame.modules[frame.plan.entry],
        frame.binding.entry,
        .{ .types = &frame.types.items, .functions = &builder.functions, .native_modules = &native_modules },
        builder.type_mappings[frame.plan.entry],
    );
}

fn seed(frame: *Frame) Error!ir.Program {
    try orderArtifactLink(frame);
    try registerArtifactTypes(frame);

    const builder = &frame.builder;

    for (frame.plan.dependencies) |index| try linkDependencySeed(builder, @intCast(index), &frame.workspace);

    const function = try builder.moduleSeed(frame.plan.entry, true);
    _ = frame.workspace.reset(.free_all);

    const retained = if (function) |*found| found else null;
    const body = if (retained) |value| &value.body else null;
    const recursive = if (retained) |value| value.recursive else null;
    const owned = frame.owned.allocator();

    if (recursive != null) try builder.functions.append(owned, body.?.*);

    const tables: result.Tables = .{
        .types = frame.types.items.view(),
        .functions = builder.functions.view(),
        .native_modules = builder.native_modules.view(),
    };

    const program = try result.materialize(owned, &frame.modules[frame.plan.entry], body, recursive, tables, builder.type_mappings[frame.plan.entry]);

    if (try @import("../ir/validate.zig").validate(frame.temporary.allocator(), program) != null) return error.InvalidIr;

    return program;
}

fn linkDependencySeed(builder: *Builder, index: usize, scratch: *std.heap.ArenaAllocator) Error!void {
    const function = try builder.moduleSeed(index, false);

    if (!scratch.reset(.retain_capacity)) return error.OutOfMemory;
    if (builder.modules[index].stores.count() != 0) return error.InvalidModule;

    if (function) |body| {
        builder.module_functions[index] = @fromBackingInt(@intCast(builder.functions.count()));

        try builder.functions.append(builder.allocator, body.body);
    }
}
