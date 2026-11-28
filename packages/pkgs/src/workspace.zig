const std = @import("std");
const rules = @import("pkgs_source");

pub const Specifier = union(enum) {
    external,
    invalid,
    path: []const u8,
    named: struct { name: []const u8, range: ?[]const u8 },
};

pub fn parse(name: []const u8, text: []const u8) Specifier {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const spec = rules.specifier.executeValue(empty.allocator(), &.{ .name = name, .requirement = text }) catch unreachable;

    return switch (spec.kind) {
        .External => .external,
        .Invalid => .invalid,
        .Path => .{ .path = spec.path.? },
        .Alias, .Name => .{ .named = .{
            .name = spec.name.?,
            .range = spec.range,
        } },
    };
}

pub fn validPath(owner: []const u8, path: []const u8, kind: @FieldType(@typeInfo(rules.workspace_path.Input).pointer.child, "kind")) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rules.workspace_path.executeIn(empty.allocator(), &.{ .owner = owner, .path = path, .kind = kind }) catch unreachable;
}

pub fn checkOwner(spec: Specifier, owner: []const u8) !void {
    switch (spec) {
        .external, .invalid => return error.InvalidLockWorkspaceTarget,
        .path => |path| if (!validPath(owner, path, .Dependency)) return error.InvalidLockWorkspacePath,
        .named => {},
    }
}

pub const Members = @import("workspace/selection.zig").Members;
pub const find = @import("workspace/selection.zig").find;
pub const matches = @import("workspace/selection.zig").matches;
pub const manifest = @import("workspace/manifest.zig");
