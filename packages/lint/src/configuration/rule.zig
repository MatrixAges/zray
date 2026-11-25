const std = @import("std");
const generated = @import("generated");
const Input = std.meta.Child(generated.Input);
const FieldItem = std.meta.Child(std.meta.Child(@FieldType(Input, "fields")));
pub const Edit = struct { start: usize, end: usize, replacement: []const u8 };

pub fn checkLength(text: []const u8, maximum: ?usize) ?usize {
    var storage: [0]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var arena = std.heap.ArenaAllocator.init(fixed.allocator());

    defer arena.deinit();

    const output = generated.executeIn(&arena, &.{
        .check_length = true,
        .source = text,
        .maximum = if (maximum) |limit| @intCast(limit) else null,
        .fields = &.{},
    }) catch unreachable;

    return if (output.lines) |lines| @intCast(lines) else null;
}

pub fn yamlEdits(allocator: std.mem.Allocator, source: []const u8, fields: anytype) std.mem.Allocator.Error![]Edit {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const values = try temporary.alloc(*const FieldItem, fields.len);

    for (fields, values) |field, *slot| {
        const item = try temporary.create(FieldItem);

        item.* = .{ .start = field.span.start, .end = field.span.end, .preserve_trailing = field.preserve_trailing };
        slot.* = item;
    }

    const output = generated.executeIn(temporary, &.{ .check_length = false, .source = source, .maximum = null, .fields = values }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const result = try allocator.alloc(Edit, output.edits.len);

    for (output.edits, result) |item, *target| {
        target.* = .{
            .start = @intCast(item.start),
            .end = @intCast(item.end),
            .replacement = if (item.crlf) (if (item.separate) "\r\n\r\n" else "\r\n") else (if (item.separate) "\n\n" else "\n"),
        };
    }

    return result;
}
