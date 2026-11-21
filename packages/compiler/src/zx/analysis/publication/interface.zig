const std = @import("std");
const zx = @import("zx");
const surface = @import("../../modules/artifact/surface.zig");

pub fn types(allocator: std.mem.Allocator, names: []const []const u8, ids: []const u32) std.mem.Allocator.Error![]const zx.ir.Export {
    const entry = @import("generated_analysis_publish_types");
    var target: []zx.memory.NamedId = &.{};
    const source: zx.memory.NamedColumns = .{ .names = names, .ids = ids };

    const request: std.meta.Child(entry.Input) = .{
        .source = @ptrCast(&source),
        .count = names.len,
        .target = @ptrCast(&target),
    };

    entry.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return @ptrCast(target);
}

pub fn constants(allocator: std.mem.Allocator, scope: anytype, first: u64) std.mem.Allocator.Error![]const zx.ir.Constant {
    const entry = @import("generated_analysis_publish_constants");
    const Input = std.meta.Child(entry.Input);
    const Scope = @typeInfo(@FieldType(Input, "scope")).optional.child;
    var target: surface.constantOutput(std.meta.Child(@FieldType(Input, "target"))) = undefined;

    target.init();

    const request: Input = .{
        .scope = if (scope) |values| zx.columns.pointer(Scope, values) else null,
        .first = first,
        .storage = @ptrCast(&target.buffer),
        .target = &target.view,
    };

    const valid = entry.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!valid) unreachable;

    return target.rows();
}
