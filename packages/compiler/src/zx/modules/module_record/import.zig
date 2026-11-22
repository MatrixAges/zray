const std = @import("std");
const zx = @import("zx");
const Record = @import("../module_record.zig");
const rule = @import("generated_module_record_import");

/// The project arena owns partial materialization, including failed allocations.
pub fn copy(allocator: std.mem.Allocator, item: anytype, target: Record.Target, identity: ?[]const u8) std.mem.Allocator.Error!Record.Import {
    const storage = item.header.storage;
    const row = storage.imports[item.index];
    const first: usize = @intCast(row.first);
    const count: usize = @intCast(row.count);
    const Input = std.meta.Child(rule.Input);
    const Names = std.meta.Child(@FieldType(Input, "names"));

    const input: Input = .{
        .names = &.{
            .source = item.header.source,
            .locals = zx.columns.slice(@FieldType(Names, "locals"), storage.import_names[first..][0..count]),
            .originals = zx.columns.slice(@FieldType(Names, "originals"), storage.import_sources[first..][0..count]),
        },
        .specifier = item.path,
        .identity = identity,
        .target = &.{ .path = target.path, .instance = target.instance, .member = target.member },
        .compiled = target.kind == .compiled,
        .release = @ptrCast(&allocator),
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .kind = item.kind,
        .exported = item.exported,
        .wildcard = item.wildcard,
        .span = item.span,
        .specifier = result.specifier,
        .identity = result.identity,
        .names = result.locals,
        .source_names = result.originals,
        .target = .{ .kind = target.kind, .path = result.path, .instance = result.instance, .member = result.member },
    };
}
