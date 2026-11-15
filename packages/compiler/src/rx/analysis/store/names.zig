const std = @import("std");
const zx = @import("zx");
pub const Kind = enum { identity, reference };

pub fn qualify(allocator: std.mem.Allocator, scope: []const u8, object: []const u8, kind: Kind) std.mem.Allocator.Error![]const u8 {
    if (comptime !@import("rx_options").generated_graph) {
        return std.fmt.allocPrint(allocator, "store.{s}{c}{s}", .{ scope, @as(u8, if (kind == .identity) ':' else '.'), object });
    }

    const rule = @import("generated_rx_store_slot_name");
    const input: std.meta.Child(rule.Input) = .{ .scope = scope, .object = object, .identity = kind == .identity };

    return zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };
}
