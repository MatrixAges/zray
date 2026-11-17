const std = @import("std");
const zx = @import("zx");
const registry = @import("../target/registry.zig");
const interface = @import("../../interface.zig");
const enabled = @import("parser_options").generated_parser;
const ExternalPlan = if (enabled) @typeInfo(@TypeOf(@import("generated_project_legacy_plan").executeValue(undefined, undefined))).error_union.payload else void;

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

pub fn legacyPlan(allocator: std.mem.Allocator, rows: []const interface.External, first: usize, specifier: []const u8, local: []const u8) std.mem.Allocator.Error!ExternalPlan {
    const generated = @import("generated_project_legacy_plan");
    const Input = std.meta.Child(generated.Input);
    const memory = zx.memory;
    const specifiers = memory.borrowTextColumn("specifier", rows);
    const exports = memory.borrowReadColumn(?[]const u8, "export_name", rows);

    const input: Input = .{
        .specifiers = &.{ .items = @ptrCast(&specifiers), .length = specifiers.count },
        .exports = @ptrCast(&exports),
        .first = first,
        .specifier = specifier,
        .local = local,
    };

    return zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}

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
