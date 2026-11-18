const std = @import("std");
const memory = @import("zx").memory;
const Growth = @import("growth.zig");

pub fn Output(comptime Input: type, comptime field: []const u8, comptime Row: type, comptime fields: anytype) type {
    const Target = std.meta.Child(@FieldType(Input, field));

    return memory.RowOutput(Row, std.meta.Child(@FieldType(Target, "columns")), fields);
}

pub fn Normalized(comptime Input: type) type {
    return Output(Input, "normalized", Growth.Normalized, .{ .keys = &.{"id"}, .wants = &.{"want"} });
}

pub fn Renewed(comptime Input: type) type {
    return Output(Input, "renewed", Growth.Renewed, .{ .keys = &.{"key"}, .wants = &.{"want"} });
}
