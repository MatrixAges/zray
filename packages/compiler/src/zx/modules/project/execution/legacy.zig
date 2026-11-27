const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const External = @import("../../interface.zig").External;
const Function = @import("../../function_import.zig");
const Native = @import("native.zig");

const Frame = struct {
    project: *Project,
    registry: []const External,
    imports: *std.ArrayList(Function),
    span: zx.Span,
    function: Function = undefined,
    namespace: ?[]const u8 = null,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn bind(project: *Project, registry: []const External, first: usize, item: anytype, imports: *std.ArrayList(Function)) zx.Error!void {
    const rule = @import("generated_project_publish_external");
    const specifiers = zx.memory.borrowTextColumn("specifier", registry);
    const exports = zx.memory.borrowReadColumn(?[]const u8, "export_name", registry);
    var frame: Frame = .{ .project = project, .registry = registry, .span = item.span, .imports = imports };

    const input: std.meta.Child(rule.Input) = .{
        .target = @ptrCast(&frame),
        .specifiers = &.{ .items = @ptrCast(&specifiers), .length = specifiers.count },
        .exports = @ptrCast(&exports),
        .first = first,
        .specifier = item.path,
        .local = item.nameAt(0).text,
    };

    const temporary = project.bindingAllocator();

    const valid = zx.columns.invoke(rule.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        error.InvalidSource => return error.InvalidSource,
        else => unreachable,
    };

    if (!valid) return project.externalCollision(item.span);
}

pub fn materializeProjectExternal(handle: *anyopaque, row: u64) zx.Error!void {
    const frame = Frame.borrow(handle);
    const entry = &frame.registry[@intCast(row)];
    const id = try Native.register(frame.project, entry.specifier, entry.identity, entry.implementation.module, frame.span);
    frame.function = try @import("../../external/host.zig").load(frame.project, entry, id, frame.span);
}

pub fn appendProjectExternal(handle: *anyopaque, name: []const u8, namespace: ?[]const u8) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const allocator = frame.project.allocator;

    try frame.imports.ensureUnusedCapacity(allocator, 1);

    const owned_name = try allocator.dupe(u8, name);

    errdefer allocator.free(owned_name);

    if (namespace) |label| {
        if (frame.namespace == null) frame.namespace = try allocator.dupe(u8, label);
    }

    frame.function.name = owned_name;
    frame.function.namespace = frame.namespace;

    frame.imports.appendAssumeCapacity(frame.function);
}
