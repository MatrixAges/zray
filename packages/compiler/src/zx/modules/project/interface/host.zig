const std = @import("std");
const zx = @import("zx");
const registry = @import("../target/registry.zig");
const interface = @import("../../interface.zig");

pub const Route = union(enum) { native: *const interface.Native, legacy: usize, duplicate, conflict, invalid_legacy, missing_legacy };

pub fn selected(scoped: []const interface.Native, result: anytype) Route {
    return switch (result.route) {
        .Native => .{ .native = switch (result.native.?.source) {
            .Standard => &interface.standard[@intCast(result.native.?.index)],
            .Scoped => &scoped[@intCast(result.native.?.index)],
        } },
        .Legacy => .{ .legacy = @intCast(result.external.?) },
        .Duplicate => .duplicate,
        .Conflict => .conflict,
        .InvalidLegacy => .invalid_legacy,
        .MissingLegacy => .missing_legacy,
    };
}

pub fn routeSeed(scoped: []const interface.Native, externals: []const interface.External, item: anytype) Route {
    return switch (registry.native(scoped, item.path, true)) {
        .duplicate => .duplicate,
        .found => |entry| if (registry.select(externals, "specifier", item.path, false).first != null) .conflict else .{ .native = entry },
        .missing => if (item.kind != .function or item.nameCount() != 1)
            .invalid_legacy
        else if (registry.select(externals, "specifier", item.path, false).first) |index|
            .{ .legacy = index }
        else
            .missing_legacy,
    };
}

pub const Binding = struct {
    name: []const u8,
    namespace: ?[]const u8,
};

pub const Legacy = struct {
    names: std.StringHashMapUnmanaged(void) = .empty,
    previous_default: bool = false,
    pub fn bind(self: *Legacy, allocator: std.mem.Allocator, export_name: ?[]const u8, local: []const u8) std.mem.Allocator.Error!?Binding {
        const count = self.names.count();
        const claimed = try self.names.getOrPut(allocator, export_name orelse "");

        if (claimed.found_existing or (count != 0 and (self.previous_default or export_name == null))) return null;

        self.previous_default = export_name == null;

        return .{
            .name = export_name orelse local,
            .namespace = if (export_name != null) local else null,
        };
    }
};
