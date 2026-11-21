const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Native = @import("../../interface.zig").Native;
const Cache = @import("../../semantic_cache/native.zig");
const Verified = @import("../../../ir/validate.zig").Verified;
const Loaded = @import("../../native.zig");
const generated = @import("parser_options").generated_parser;

const Verification = struct {
    slot: [1]*usize,
    functions: zx.memory.ColumnLengths,
    native: []u8,
    fn init(self: *Verification, verified: *Verified) void {
        self.slot = .{&verified.functions};
        self.functions = &self.slot;
        self.native = @as(*[1]u8, @ptrCast(&verified.native));
    }
    fn input(self: *const Verification, comptime Input: type) Input {
        return .{ .functions = @ptrCast(&self.functions), .native = @ptrCast(&self.native) };
    }
};

const Frame = struct {
    project: *Project,
    native: *const Native,
    module: zx.ir.NativeModuleId,
    span: zx.Span,
    result: Loaded.Result = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn invalidate(verified: *Verified) void {
    if (comptime generated) {
        const entry = @import("generated_project_invalidate_native");
        var columns: Verification = undefined;

        columns.init(verified);

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input = columns.input(std.meta.Child(entry.Input));

        zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
    } else {
        verified.functions = 0;
        verified.native = false;
    }
}

pub fn load(project: *Project, native: *const Native, module: zx.ir.NativeModuleId, span: zx.Span) zx.Error!Loaded.Result {
    var frame: Frame = .{ .project = project, .native = native, .module = module, .span = span };
    const cached = project.semantic_cache != null;

    if (comptime generated) {
        const entry = @import("generated_project_execute_native");
        const Input = std.meta.Child(entry.Input);
        var columns: Verification = undefined;

        columns.init(&project.verified);

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input: Input = .{ .frame = @ptrCast(&frame), .cached = cached, .verified = &columns.input(std.meta.Child(@FieldType(Input, "verified"))) };

        entry.executeIn(empty.allocator(), &input) catch |err| return @import("invoke.zig").errorSet(err);
    } else if (cached) {
        try loadCachedProjectNative(&frame);
    } else {
        try loadFreshProjectNative(&frame);
    }

    return frame.result;
}

pub fn loadCachedProjectNative(handle: *const anyopaque) zx.Error!void {
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

pub fn loadFreshProjectNative(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const project = frame.project;
    const loaded = try Loaded.load(project.arena, frame.native.*, frame.module, &project.types, &project.nominal_origins, &project.functions, project.reporter, frame.span);

    if (comptime generated) try @import("../../link/signature/publication/host.zig").finalizeNative(project.allocator, &project.native_modules, &project.functions, frame.module, loaded, frame.native.namespace);

    frame.result = loaded;
}
