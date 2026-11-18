const std = @import("std");
const memory = @import("zx").memory;
const Growth = @import("growth.zig");

pub fn Target(comptime Input: type, comptime field: []const u8) type {
    const Field = @FieldType(Input, field);

    return std.meta.Child(if (@typeInfo(Field) == .optional) @typeInfo(Field).optional.child else Field);
}

pub fn Output(comptime Input: type, comptime field: []const u8, comptime Row: type, comptime fields: anytype) type {
    return memory.RowOutput(Row, std.meta.Child(@FieldType(Target(Input, field), "columns")), fields);
}

pub fn Normalized(comptime Input: type) type {
    return Output(Input, "normalized", Growth.Normalized, .{ .keys = &.{"id"}, .wants = &.{"want"} });
}

pub fn Renewed(comptime Input: type) type {
    return Output(Input, "renewed", Growth.Renewed, .{ .keys = &.{"key"}, .wants = &.{"want"} });
}

pub fn Contributions(comptime Input: type, comptime field: []const u8) type {
    return Output(Input, field, @import("function.zig").Contribution, .{ .callees = &.{"callee"}, .levels = &.{"levels"} });
}

pub fn Marks(comptime Input: type, comptime field: []const u8) type {
    return Output(Input, field, @import("function.zig").Mark, .{
        .output = &.{"output"},
        .functions = &.{"function"},
        .slots = &.{"slot"},
        .wants = &.{"want"},
    });
}

pub fn Reads(comptime Input: type) type {
    return Output(Input, "read_target", @import("function.zig").Read, .{
        .tables = &.{"table"},
        .functions = &.{"function"},
        .slots = &.{"slot"},
        .levels = &.{"value"},
    });
}
