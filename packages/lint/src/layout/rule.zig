const std = @import("std");
const generated = @import("generated");

pub const Token = struct {
    block: bool = false,
    boundary: bool = false,
    closing: bool = false,
    comment: bool = false,
    end: u64,
    gap: u64 = 0,
    newline: bool = false,
    object: bool = false,
    multiline: bool = false,
    opening: bool = false,
    separator: bool = false,
    start: u64,
    text: []const u8,
};

pub const Edit = struct { start: usize, end: usize, newline: bool, count: usize };

pub const Options = struct {
    width: usize = 0,
    level: usize = 0,
    indent_only: bool = false,
    prefix: usize = 0,
    suffix: usize = 0,
};

pub fn attributeRequired(source: []const u8, level: usize, prefix: usize) bool {
    var storage: [0]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);

    const output = generated.executeIn(fixed.allocator(), &.{
        .source = source,
        .layout = &.{ .tokens = &.{}, .width = 0, .level = level, .indent_only = false, .prefix = prefix, .suffix = 0 },
        .check_attribute = true,
    }) catch unreachable;

    return output.required;
}

pub fn edits(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, options: Options) std.mem.Allocator.Error![]const Edit {
    const Input = std.meta.Child(generated.Input);
    const Layout = std.meta.Child(@FieldType(Input, "layout"));
    const Item = std.meta.Child(std.meta.Child(@FieldType(Layout, "tokens")));
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const values = try temporary.alloc(*const Item, tokens.len);

    for (tokens, values) |token, *slot| {
        const value = try temporary.create(Item);

        inline for (@typeInfo(Item).@"struct".field_names) |name| @field(value, name) = @field(token, name);

        slot.* = value;
    }

    const output = generated.executeIn(temporary, &.{
        .source = source,
        .layout = &.{ .tokens = values, .width = options.width, .level = options.level, .indent_only = options.indent_only, .prefix = options.prefix, .suffix = options.suffix },
        .check_attribute = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const result = try allocator.alloc(Edit, output.edits.len);

    for (result, output.edits) |*item, value| item.* = .{ .start = @intCast(value.start), .end = @intCast(value.end), .newline = value.newline, .count = @intCast(value.count) };

    return result;
}
