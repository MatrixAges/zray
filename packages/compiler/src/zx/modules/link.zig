const std = @import("std");
const ir = @import("zx").ir;
const model = @import("artifact/model.zig");
const Origins = @import("nominal_origins.zig");
const Types = @import("link/types.zig");
const Builder = @import("link/build.zig");
const graph = @import("link/graph.zig");
const result = @import("link/result/host.zig");
const steps = @import("link/artifact/steps.zig");
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

pub fn link(allocator: std.mem.Allocator, modules: []const model.Module, entry: []const u8) Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var temporary = std.heap.ArenaAllocator.init(allocator);

    defer temporary.deinit();

    var module_scratch = std.heap.ArenaAllocator.init(allocator);

    defer module_scratch.deinit();

    const owned = arena.allocator();
    const scratch = temporary.allocator();
    const workspace = module_scratch.allocator();
    var plan: graph.Plan = undefined;
    var mappings: [][]const ir.TypeId = undefined;
    var function_ids: []?ir.FunctionId = undefined;
    var types: Types = undefined;
    var builder: Builder = undefined;
    var entry_index: usize = undefined;
    var function: ?@import("artifact/nodes.zig").FunctionEntry = undefined;

    inline for (comptime steps.run(.Graph)) |step| {
        switch (step) {
            .PrepareGraph => {
                plan = try graph.prepare(scratch, allocator, modules, entry);
                mappings = try scratch.alloc([]const ir.TypeId, modules.len);
                function_ids = try scratch.alloc(?ir.FunctionId, modules.len);
                types = try Types.init(owned);

                @memset(function_ids, null);
            },
            .MergeTypes => {
                for (plan.order) |index| {
                    mappings[index] = try types.appendTemporary(scratch, workspace, &modules[index]);

                    if (!module_scratch.reset(.retain_capacity)) return error.OutOfMemory;
                }
            },
            .LinkDependencies => {
                builder = .{ .allocator = owned, .temporary = workspace, .modules = modules, .plan = plan, .type_mappings = mappings, .module_functions = function_ids };
                const end = plan.order.len - 1;

                for (plan.order[0..end]) |index| try linkDependency(&builder, index, &module_scratch);
            },
            .LinkEntry => {
                entry_index = plan.order[plan.order.len - 1];
                function = try builder.module(entry_index, true);
                _ = module_scratch.reset(.free_all);
            },
            .PublishProgram => {
                const body = if (function) |*value| &value.body else null;
                const recursive = if (function) |*value| value.recursive else null;

                if (recursive != null) try builder.functions.append(owned, body.?.*);

                const program = try result.materialize(owned, scratch, &modules[entry_index], body, recursive, .{
                    .types = types.items.view(),
                    .functions = builder.functions.view(),
                    .native_modules = builder.native_modules.view(),
                }, mappings[entry_index]);

                return .{ .arena = arena, .program = program, .nominal_types = types.origins.items.view() };
            },
            else => unreachable,
        }
    }

    unreachable;
}

fn linkDependency(builder: *Builder, index: usize, scratch: *std.heap.ArenaAllocator) Error!void {
    const module = &builder.modules[index];
    const function = try builder.module(index, false);

    if (!scratch.reset(.retain_capacity)) return error.OutOfMemory;
    if (builder.module_functions[index] != null) return;

    switch (@import("link/placement.zig").select(module.stores.count(), function != null)) {
        .Invalid => return error.InvalidModule,
        .Skip => {},
        .Append => {
            builder.module_functions[index] = @fromBackingInt(@as(u32, @intCast(builder.functions.count())));

            try builder.functions.append(builder.allocator, function.?.body);
        },
    }
}
