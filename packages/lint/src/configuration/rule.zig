const std = @import("std");
const generated = @import("generated");
const Input = std.meta.Child(generated.Input);
const FieldItem = std.meta.Child(std.meta.Child(@FieldType(Input, "fields")));

pub fn checkLength(text: []const u8, maximum: ?usize) ?usize {
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);

    const output = generated.executeIn(fixed.allocator(), &.{
        .check_length = true,
        .source = text,
        .maximum = if (maximum) |limit| @intCast(limit) else null,
        .fields = &.{},
    }) catch unreachable;

    return if (output.lines) |lines| @intCast(lines) else null;
}

pub fn formatYaml(allocator: std.mem.Allocator, source: []const u8, fields: anytype) std.mem.Allocator.Error!?[]u8 {
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

    return if (output.formatted) |text| try allocator.dupe(u8, text) else null;
}
