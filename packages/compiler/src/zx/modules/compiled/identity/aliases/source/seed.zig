const std = @import("std");
const interface = @import("../../../../interface.zig");
const Error = @import("../../../identity.zig").DeclarationError;

pub fn resolve(allocator: std.mem.Allocator, interfaces: []const interface.Native, externals: []const interface.External, comptime Alias: type, configured: ?[]const Alias) Error![]const Alias {
    var aliases: std.ArrayList(Alias) = .empty;

    errdefer aliases.deinit(allocator);

    if (configured) |entries| {
        for (entries) |entry| {
            var target: ?[]const u8 = null;

            for (interfaces) |declaration| {
                if (std.mem.eql(u8, entry.specifier, declaration.specifier)) target = declaration.key();
            }

            for (externals) |declaration| {
                if (std.mem.eql(u8, entry.specifier, declaration.specifier)) target = declaration.key();
            }

            try append(allocator, Alias, &aliases, .{ .name = entry.name, .specifier = target orelse return error.UnknownNativeAbiAlias });
        }
    } else {
        for (interfaces) |entry| try append(allocator, Alias, &aliases, .{ .name = entry.specifier, .specifier = entry.key() });
        for (externals) |entry| try append(allocator, Alias, &aliases, .{ .name = entry.specifier, .specifier = entry.key() });
    }

    return aliases.toOwnedSlice(allocator);
}

fn append(allocator: std.mem.Allocator, comptime Alias: type, aliases: *std.ArrayList(Alias), value: Alias) Error!void {
    for (aliases.items) |previous| {
        if (!std.mem.eql(u8, previous.name, value.name)) continue;
        if (!std.mem.eql(u8, previous.specifier, value.specifier)) return error.ConflictingNativeAbiAlias;

        return;
    }

    try aliases.append(allocator, value);
}
