const std = @import("std");
const zx = @import("zx");
const rule = @import("generated_rx_args_validate");
const Input = std.meta.Child(rule.Input);
const Names = std.meta.Child(@FieldType(Input, "names"));

pub const Admission = struct { valid: bool, mismatch: ?usize };

pub fn indexed(text: []const u8, output: anytype, expected: []const []const u8, ends: ?[]const u64) Admission {
    const names: Names = .{
        .text = text,
        .expected = expected,
        .declarations = zx.columns.slice(@FieldType(Names, "declarations"), output.declarations),
        .ends = ends,
    };

    const input: Input = .{
        .has_imports = output.imports.len != 0,
        .has_constants = output.constants.len != 0,
        .has_contracts = output.contracts.len != 0,
        .has_body = output.body != null,
        .has_store = output.has_store,
        .names = &names,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .valid = result.valid, .mismatch = if (result.mismatch) |row| @intCast(row) else null };
}
