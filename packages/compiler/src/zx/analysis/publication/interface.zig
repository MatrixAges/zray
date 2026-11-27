const std = @import("std");
const zx = @import("zx");

pub fn types(allocator: std.mem.Allocator, names: []const []const u8, ids: []const u32) std.mem.Allocator.Error![]const zx.ir.Export {
    const entry = @import("generated_analysis_publish_types");
    const source: zx.memory.NamedColumns = .{ .names = names, .ids = ids };

    const request: std.meta.Child(entry.Input) = .{
        .source = @ptrCast(&source),
        .count = names.len,
    };

    const rows = entry.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (rows.len == 0) return &.{};

    const result = try allocator.alloc(zx.ir.Export, rows.len);

    for (rows, result) |row, *slot| {
        slot.* = .{ .name = row.name, .type_id = @fromBackingInt(row.type_id) };
    }

    return result;
}

pub fn constants(allocator: std.mem.Allocator, scope: anytype, first: u64) std.mem.Allocator.Error![]const zx.ir.Constant {
    const entry = @import("generated_analysis_publish_constants");
    const Input = std.meta.Child(entry.Input);
    const Scope = @typeInfo(@FieldType(Input, "scope")).optional.child;

    const request: Input = .{
        .scope = if (scope) |values| zx.columns.pointer(Scope, values) else null,
        .first = first,
    };

    const output = entry.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) unreachable;
    if (output.rows.len == 0) return &.{};

    const result = try allocator.alloc(zx.ir.Constant, output.rows.len);

    for (output.rows, result) |row, *slot| {
        slot.* = .{
            .name = row.name,
            .type_id = @fromBackingInt(row.type_id),
            .value = switch (row.kind) {
                .Integer => if (row.negative) .{ .negative_integer = row.integer } else .{ .integer = row.integer },
                .Float => .{ .float = row.floating },
                .String => .{ .string = row.text },
                .Boolean => .{ .boolean = row.boolean },
                .EnumValue => .{ .enumeration = row.enumeration },
                else => unreachable,
            },
        };
    }

    return result;
}
