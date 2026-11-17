const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Record = @import("../../module_record.zig");
const Error = @import("../model.zig").Error;
const generated = @import("generated_artifact_dependency_publication");
const Input = std.meta.Child(generated.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));

pub fn dependencies(allocator: std.mem.Allocator, source: []const Record.Import) Error![]const Record.Import {
    if (source.len == 0) return &.{};

    const result = try allocator.dupe(Record.Import, source);
    const header = @import("../../module_record/columns.zig").borrow(source);

    const input: Input = .{
        .source = &.{
            .header = &header.view(std.meta.Child(@FieldType(Source, "header"))),
            .names = @ptrCast(&memory.borrowReadColumn([]const []const u8, "names", source)),
            .source_names = @ptrCast(&memory.borrowReadColumn([]const []const u8, "source_names", source)),
            .path = @ptrCast(&memory.borrowNestedColumn([]const u8, &.{ "target", "path" }, source)),
        },
        .target = &.{
            .specifier = @ptrCast(&memory.borrowWriteColumn([]const u8, "specifier", result)),
            .identity = @ptrCast(&memory.borrowWriteColumn(?[]const u8, "identity", result)),
            .names = @ptrCast(&memory.borrowWriteColumn([]const []const u8, "names", result)),
            .source_names = @ptrCast(&memory.borrowWriteColumn([]const []const u8, "source_names", result)),
            .path = @ptrCast(&memory.borrowNestedWriteColumn([]const u8, &.{ "target", "path" }, result)),
        },
    };

    zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return result;
}
