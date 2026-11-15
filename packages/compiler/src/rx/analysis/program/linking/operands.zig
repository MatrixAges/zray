const std = @import("std");
const zx = @import("zx");
const Builder = @import("../builder.zig");
const Mapping = @import("../mapping.zig");

pub fn symbolView(comptime Target: type, mapping: *const Mapping) Target {
    return .{ .bindings = mapping.bindings, .locals_base = mapping.locals_base, .count = mapping.symbol_count };
}

pub fn invoke(comptime rule: type, input: std.meta.Child(rule.Input)) Builder.Error!@typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.IndexOutOfBounds, error.IntegerOverflow => return error.InvalidModule,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
