const std = @import("std");
const zx = @import("zx");

pub const Mode = enum { full, comments, none };

pub fn execute(comptime parser: type, comptime mode: Mode, scratch: std.mem.Allocator, rows: ?*zx.Arena, source: []const u8) @typeInfo(@TypeOf(parser.executeIn)).@"fn".return_type.? {
    const Input = std.meta.Child(parser.Input);
    const Placement = std.meta.Child(@typeInfo(@FieldType(Input, "placement")).optional.child);

    const arena = rows orelse return parser.executeIn(scratch, &.{
        .source = source,
        .placement = null,
        .omit_tokens = mode != .full,
        .omit_comments = mode == .none,
    });

    const result = arena.allocator();
    var scope: zx.memory.ArenaScope = .{ .active = scratch };

    const placement: Placement = .{
        .scope = @ptrCast(&scope),
        .comments = if (mode != .none) @ptrCast(&result) else null,
        .tokens = if (mode == .full) @ptrCast(&result) else null,
        .rows = @ptrCast(&result),
        .scratch = @ptrCast(&scratch),
    };

    return parser.executeIn(scope.allocator(), &.{
        .source = source,
        .placement = &placement,
        .omit_tokens = mode != .full,
        .omit_comments = mode == .none,
    });
}
