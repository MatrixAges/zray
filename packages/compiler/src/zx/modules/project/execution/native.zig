const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Native = @import("../../interface.zig").Native;
const Cache = @import("../../semantic_cache/native.zig");
const Verified = @import("../../../ir/validate.zig").Verified;
const Loaded = @import("../../native.zig");
const generated = @import("parser_options").generated_parser;

pub fn invalidateSeed(verified: *Verified) void {
    verified.functions = 0;
    verified.native = false;
}

pub fn register(project: *Project, source: []const u8, identity: ?[]const u8, name: []const u8, span: zx.Span) zx.Error!zx.ir.NativeModuleId {
    const rule = @import("generated_project_register_native");
    const Input = std.meta.Child(rule.Input);

    const input: Input = .{
        .modules = &zx.columns.columns(std.meta.Child(@FieldType(Input, "modules")), project.native_modules.view()),
        .names = &.{ .specifier = source, .identity = identity, .import_name = name },
    };

    var arena = std.heap.ArenaAllocator.init(project.arena.child_allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const selected = rule.executeIn(scratch.allocator(), &input) catch |err| return @import("invoke.zig").errorSet(err);

    if (!selected.valid) return project.reporter.fail(.module, span, "native import names must be nonempty UTF-8 strings");

    const id = selected.id orelse return error.OutOfMemory;

    if (selected.append) |names| {
        const allocator = project.allocator;
        const specifier = try allocator.dupe(u8, names.specifier);

        errdefer allocator.free(specifier);

        const import_name = try allocator.dupe(u8, names.import_name);

        errdefer allocator.free(import_name);

        const owned_identity = if (names.identity) |value| try allocator.dupe(u8, value) else null;

        errdefer if (owned_identity) |value| allocator.free(value);

        try project.native_modules.append(allocator, .{
            .specifier = specifier,
            .identity = owned_identity,
            .import_name = import_name,
        });
    }

    if (selected.verified) |reset| {
        project.verified.functions = @intCast(reset.functions);
        project.verified.native = reset.native;
    }

    return @fromBackingInt(id);
}

pub fn load(project: *Project, native: *const Native, module: zx.ir.NativeModuleId, span: zx.Span) zx.Error!Loaded.Result {
    const cached = project.semantic_cache != null;

    if (comptime generated) {
        const entry = @import("generated_project_execute_native");
        const Input = std.meta.Child(entry.Input);
        const input: Input = .{ .cached = cached };
        var arena = std.heap.ArenaAllocator.init(project.arena.child_allocator);

        defer arena.deinit();

        var buffer: [512]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
        const plan = entry.executeIn(scratch.allocator(), &input) catch |err| return @import("invoke.zig").errorSet(err);

        const loaded = switch (plan.loader) {
            .Fresh => try @import("../../native/delivery/host.zig").load(project, native, module, span),
            .Cached => try loadCached(project, native, module, span),
        };

        project.verified.functions = @intCast(plan.verified.functions);
        project.verified.native = plan.verified.native;

        return loaded;
    }

    if (cached) return loadCached(project, native, module, span);

    return Loaded.loadSeed(project.arena, native.*, module, .{ .types = &project.types, .origins = &project.nominal_origins }, project.reporter, span);
}

fn loadCached(project: *Project, native: *const Native, module: zx.ir.NativeModuleId, span: zx.Span) zx.Error!Loaded.Result {
    const current: Cache.Current = .{
        .module = module,
        .types = &project.types,
        .origins = &project.nominal_origins,
        .functions = &project.functions,
        .modules = &project.native_modules,
        .backing = project.arena.child_allocator,
    };

    return project.semantic_cache.?.native.load(project.allocator, native.*, current, project.reporter, span);
}
