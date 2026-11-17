const std = @import("std");
const Compiled = @import("../compiled.zig").Target;
const Self = @This();
pub const Kind = enum(u8) { source, compiled, native, external, intrinsic };

pub const Wire = union(Kind) {
    source: []const u8,
    compiled: Compiled,
    native,
    external,
    intrinsic,
};

kind: Kind,
path: []const u8 = &.{},

instance: []const u8 = &.{},
member: []const u8 = &.{},
pub fn from(value: Wire) Self {
    return switch (value) {
        .source => |path| .{ .kind = .source, .path = path },
        .compiled => |target| .{ .kind = .compiled, .path = target.artifact, .instance = target.instance, .member = target.name },
        .native, .external, .intrinsic => .{ .kind = std.meta.activeTag(value) },
    };
}

pub fn jsonStringify(self: Self, writer: anytype) !void {
    const wire: Wire = switch (self.kind) {
        .source => .{ .source = self.path },
        .compiled => .{ .compiled = .{ .instance = self.instance, .artifact = self.path, .name = self.member } },
        .native => .native,
        .external => .external,
        .intrinsic => .intrinsic,
    };

    try writer.write(wire);
}

pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Self {
    return from(try std.json.innerParse(Wire, allocator, source, options));
}
