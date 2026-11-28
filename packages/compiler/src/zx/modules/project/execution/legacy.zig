const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const External = @import("../../interface.zig").External;
const Function = @import("../../function_import.zig");
const Native = @import("native.zig");

pub fn bind(project: *Project, registry: []const External, first: usize, item: anytype, imports: *std.ArrayList(Function)) zx.Error!void {
    const rule = @import("generated_project_publish_external");
    const specifiers = zx.memory.borrowTextColumn("specifier", registry);
    const exports = zx.memory.borrowReadColumn(?[]const u8, "export_name", registry);

    const input: std.meta.Child(rule.Input) = .{
        .specifiers = &.{ .items = @ptrCast(&specifiers), .length = specifiers.count },
        .exports = @ptrCast(&exports),
        .first = first,
        .specifier = item.path,
        .local = item.nameAt(0).text,
    };

    var arena = std.heap.ArenaAllocator.init(project.arena.child_allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const plan = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const allocator = project.allocator;
    var namespace: ?[]const u8 = null;

    for (plan.bindings) |binding| {
        const entry = &registry[@intCast(binding.row)];
        const id = try Native.register(project, entry.specifier, entry.identity, entry.implementation.module, item.span);
        var function = try @import("../../external/host.zig").load(project, entry, id, item.span);

        try imports.ensureUnusedCapacity(allocator, 1);

        const name = try allocator.dupe(u8, binding.name);

        errdefer allocator.free(name);

        if (binding.namespace) |label| {
            if (namespace == null) namespace = try allocator.dupe(u8, label);
        }

        function.name = name;
        function.namespace = namespace;

        imports.appendAssumeCapacity(function);
    }

    if (!plan.valid) return project.externalCollision(item.span);
}
