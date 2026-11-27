const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Native = @import("../../interface.zig").Native;
const Cache = @import("../../semantic_cache/native.zig");
const Verified = @import("../../../ir/validate.zig").Verified;
const Loaded = @import("../../native.zig");
const generated = @import("parser_options").generated_parser;

const Frame = struct {
    project: *Project,
    native: *const Native,
    module: zx.ir.NativeModuleId,
    span: zx.Span,
    result: Loaded.Result = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn invalidateSeed(verified: *Verified) void {
    verified.functions = 0;
    verified.native = false;
}

pub fn register(project: *Project, source: []const u8, identity: ?[]const u8, name: []const u8, span: zx.Span) zx.Error!zx.ir.NativeModuleId {
    const rule = @import("generated_project_register_native");
    const Input = std.meta.Child(rule.Input);

    const input: Input = .{
        .registry = @ptrCast(project),
        .modules = &zx.columns.columns(std.meta.Child(@FieldType(Input, "modules")), project.native_modules.view()),
        .names = &.{ .specifier = source, .identity = identity, .import_name = name },
    };

    const selected = rule.executeIn(project.allocator, &input) catch |err| return @import("invoke.zig").errorSet(err);

    if (selected.verified) |reset| {
        project.verified.functions = @intCast(reset.functions);
        project.verified.native = reset.native;
    }

    if (!selected.valid) return project.reporter.fail(.module, span, "native import names must be nonempty UTF-8 strings");

    return @fromBackingInt(selected.id orelse return error.OutOfMemory);
}

pub fn appendProjectNativeModule(handle: *anyopaque, specifier: []const u8, identity: ?[]const u8, name: []const u8) std.mem.Allocator.Error!void {
    const project: *Project = @ptrCast(@alignCast(handle));

    try project.native_modules.append(project.allocator, .{ .specifier = specifier, .identity = identity, .import_name = name });
}

pub fn load(project: *Project, native: *const Native, module: zx.ir.NativeModuleId, span: zx.Span) zx.Error!Loaded.Result {
    var frame: Frame = .{ .project = project, .native = native, .module = module, .span = span };
    const cached = project.semantic_cache != null;

    if (comptime generated) {
        const entry = @import("generated_project_execute_native");
        const Input = std.meta.Child(entry.Input);
        const input: Input = .{ .frame = @ptrCast(&frame), .cached = cached };
        const reset = entry.executeIn(project.allocator, &input) catch |err| return @import("invoke.zig").errorSet(err);
        project.verified.functions = @intCast(reset.functions);
        project.verified.native = reset.native;
    } else if (cached) {
        try loadCachedProjectNative(&frame);
    } else {
        try loadFreshProjectNative(&frame);
    }

    return frame.result;
}

pub fn loadCachedProjectNative(handle: *anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const project = frame.project;

    const current: Cache.Current = .{
        .module = frame.module,
        .types = &project.types,
        .origins = &project.nominal_origins,
        .functions = &project.functions,
        .modules = &project.native_modules,
        .backing = project.arena.child_allocator,
    };

    frame.result = try project.semantic_cache.?.native.load(project.allocator, frame.native.*, current, project.reporter, frame.span);
}

pub fn loadFreshProjectNative(handle: *anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const project = frame.project;

    frame.result = if (comptime generated)
        try @import("../../native/delivery/host.zig").load(project, frame.native, frame.module, frame.span)

    else
        try Loaded.loadSeed(project.arena, frame.native.*, frame.module, .{ .types = &project.types, .origins = &project.nominal_origins }, project.reporter, frame.span);
}
