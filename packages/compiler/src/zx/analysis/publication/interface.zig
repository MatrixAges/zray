const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const entry = @import("generated_analysis_publish_declaration");
const literals = @import("../constants/input.zig");
const Input = std.meta.Child(entry.Input);
const Owned = @typeInfo(@TypeOf(entry.executeValue(undefined, undefined))).error_union.payload;

pub fn types(allocator: std.mem.Allocator, names: []const []const u8, ids: []const u32) std.mem.Allocator.Error![]const ir.Export {
    const result = try allocator.alloc(ir.Export, names.len);

    for (names, ids, result) |name, id, *target| {
        const owned = try copy(allocator, .{ .name = name, .type_id = id, .text = null });
        target.* = .{ .name = owned.name, .type_id = @fromBackingInt(owned.type_id) };
    }

    return result;
}

pub fn constants(allocator: std.mem.Allocator, scope: anytype, offset: u64) std.mem.Allocator.Error![]const ir.Constant {
    const values = scope orelse return &.{};
    const first: usize = @intCast(offset);
    const result = try allocator.alloc(ir.Constant, values.names.len - first);

    for (values.names[first..], values.values[first..], result) |name, literal, *target| {
        var value = literals.view(literal);

        const owned = try copy(allocator, .{
            .name = name,
            .type_id = literal.type_id,
            .text = if (value == .string) value.string else null,
        });

        if (owned.text) |text| value = .{ .string = text };

        target.* = .{ .name = owned.name, .type_id = @fromBackingInt(owned.type_id), .value = value };
    }

    return result;
}

fn copy(allocator: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Owned {
    return zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
