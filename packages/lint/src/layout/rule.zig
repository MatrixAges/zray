const std = @import("std");
const generated = @import("generated");
const Input = std.meta.Child(generated.Input);
const ProjectionInput = std.meta.Child(@FieldType(Input, "projection"));
pub const RawSpan = std.meta.Child(std.meta.Child(@FieldType(ProjectionInput, "raw_tokens")));
pub const Op = std.meta.Child(std.meta.Child(@FieldType(ProjectionInput, "ops")));

pub const ProjectionData = struct {
    raw_tokens: []const RawSpan,
    raw_comments: []const RawSpan,
    ops: []const Op,
};

pub const Options = struct {
    width: usize = 0,
    level: usize = 0,
    indent_only: bool = false,
    prefix: usize = 0,
    suffix: usize = 0,
};

pub fn attributeRequired(source: []const u8, level: usize, prefix: usize) bool {
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);

    const output = generated.executeIn(fixed.allocator(), &.{
        .source = source,
        .newline = "\n",
        .layout = &.{ .tokens = &.{}, .width = 0, .level = level, .indent_only = false, .prefix = prefix, .suffix = 0 },
        .check_attribute = true,
        .projection = &.{ .source_text = "", .raw_tokens = &.{}, .raw_comments = &.{}, .ops = &.{} },
    }) catch unreachable;

    return output.required;
}

pub fn format(allocator: std.mem.Allocator, source: []const u8, projection: ProjectionData, options: Options, newline: ?[]const u8) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();

    const request: ProjectionInput = .{
        .source_text = source,
        .raw_tokens = try borrowRows(RawSpan, temporary, projection.raw_tokens),
        .raw_comments = try borrowRows(RawSpan, temporary, projection.raw_comments),
        .ops = try borrowRows(Op, temporary, projection.ops),
    };

    const output = generated.executeIn(temporary, &.{
        .source = source,
        .newline = newline,
        .layout = &.{ .tokens = &.{}, .width = options.width, .level = options.level, .indent_only = options.indent_only, .prefix = options.prefix, .suffix = options.suffix },
        .check_attribute = false,
        .projection = &request,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return allocator.dupe(u8, output.formatted);
}

fn borrowRows(comptime Row: type, allocator: std.mem.Allocator, items: []const Row) std.mem.Allocator.Error![]const *const Row {
    const pointers = try allocator.alloc(*const Row, items.len);

    for (items, pointers) |*item, *slot| slot.* = item;

    return pointers;
}
