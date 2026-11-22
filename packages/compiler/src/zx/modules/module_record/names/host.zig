const std = @import("std");

const Columns = struct {
    locals: []const []const u8,
    originals: []const []const u8 = &.{},
    specifier: []const u8,
    identity: ?[]const u8 = null,
};

pub fn own(allocator: std.mem.Allocator, item: anytype, identity: ?[]const u8) std.mem.Allocator.Error!Columns {
    const locals = try allocator.alloc([]const u8, item.nameCount());

    for (locals, 0..) |*owned, index| owned.* = try allocator.dupe(u8, item.nameAt(index).text);

    var originals: ?[][]const u8 = null;

    for (locals, 0..) |local, index| {
        const original = item.sourceAt(index).text;

        if (originals == null and !std.mem.eql(u8, local, original)) {
            originals = try allocator.alloc([]const u8, locals.len);

            @memcpy(originals.?[0..index], locals[0..index]);
        }

        if (originals) |values| values[index] = if (std.mem.eql(u8, local, original)) local else try allocator.dupe(u8, original);
    }

    return .{ .locals = locals, .originals = originals orelse &.{}, .specifier = try allocator.dupe(u8, item.path), .identity = if (identity) |name| try allocator.dupe(u8, name) else null };
}
