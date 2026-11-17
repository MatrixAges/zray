const std = @import("std");
const ir = @import("zx").ir;
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
    const plan = try graph.prepare(scratch, modules, entry);
    const mappings = try scratch.alloc([]const ir.TypeId, modules.len);
    const function_ids = try scratch.alloc(?ir.FunctionId, modules.len);
    var types = try Types.init(owned);

    @memset(function_ids, null);

    if (comptime @import("parser_options").generated_parser) {
        try @import("link/registration/host.zig").register(&types, modules, plan.registration, mappings, scratch, &module_scratch);
    } else {
        for (plan.registration) |row| {
            const index: usize = @intCast(row);

            mappings[index] = try types.appendTemporary(scratch, workspace, &modules[index]);

            if (!module_scratch.reset(.retain_capacity)) return error.OutOfMemory;
        }
    }

    var builder: Builder = .{ .allocator = owned, .temporary = workspace, .modules = modules, .plan = plan, .type_mappings = mappings, .module_functions = function_ids };

    for (plan.dependencies) |index| try linkDependency(&builder, @intCast(index), &module_scratch);

    const function = try builder.module(plan.entry, true);

    _ = module_scratch.reset(.free_all);

    const tables: result.Tables = .{
        .types = types.items.view(),
        .functions = .{},
        .native_modules = builder.native_modules.view(),
    };

    const selected = &modules[plan.entry];

    const program = if (comptime @import("parser_options").generated_parser)
        try @import("link/result/publication/host.zig").finish(owned, scratch, selected, if (function) |*found| found else null, tables, &builder.functions, mappings[plan.entry])

    else seed: {
        const body = if (function) |*value| &value.body else null;
        const recursive = if (function) |value| value.recursive else null;

        if (recursive != null) try builder.functions.append(owned, body.?.*);

        var seed_tables = tables;

        seed_tables.functions = builder.functions.view();

        break :seed try result.materialize(owned, scratch, selected, body, recursive, seed_tables, mappings[plan.entry]);
    };

    return .{ .arena = arena, .program = program, .nominal_types = types.origins.items.view() };
}

fn linkDependency(builder: *Builder, index: usize, scratch: *std.heap.ArenaAllocator) Error!void {
    const function = try builder.module(index, false);

    if (!scratch.reset(.retain_capacity)) return error.OutOfMemory;

    if (comptime !@import("parser_options").generated_parser) {
        if (builder.modules[index].stores.count() != 0) return error.InvalidModule;

        if (function) |body| {
            builder.module_functions[index] = @fromBackingInt(@intCast(builder.functions.count()));

            try builder.functions.append(builder.allocator, body.body);
        }
    }
}
