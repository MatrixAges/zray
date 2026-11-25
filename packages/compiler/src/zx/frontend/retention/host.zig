const std = @import("std");
const zx = @import("zx");
const compact = @import("../compact_output.zig");
const layout = @import("layout.zig");

pub fn retain(comptime rule: type, allocator: std.mem.Allocator, syntax: anytype) std.mem.Allocator.Error!struct { arena: zx.Arena, output: @TypeOf(syntax) } {
    const Input = std.meta.Child(rule.Input);
    const Layout = std.meta.Child(@FieldType(Input, "layout"));
    const shape = comptime layout.of(Layout, std.meta.Child(@TypeOf(syntax)));
    const input: Input = .{ .syntax = syntax, .layout = &shape };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const capacity = rule.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    var arena = try zx.Arena.initCapacity(allocator, @intCast(capacity));

    errdefer arena.deinit();

    const output = try compact.retainSyntax(arena.allocator(), syntax);

    std.debug.assert(arena.queryCapacity() == capacity);

    return .{ .arena = arena, .output = output };
}
