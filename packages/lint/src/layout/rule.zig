const std = @import("std");
const generated = @import("generated");
const Input = std.meta.Child(generated.Input);
const ProjectionInput = std.meta.Child(@FieldType(Input, "projection"));
const Span = std.meta.Child(std.meta.Child(@FieldType(ProjectionInput, "raw_tokens")));
const AbiOp = std.meta.Child(std.meta.Child(@FieldType(ProjectionInput, "ops")));
pub const RawSpan = struct { start: u64, end: u64 };
pub const OpKind = @FieldType(AbiOp, "kind");

pub const Op = struct {
    kind: OpKind,
    start: u64 = 0,
    end: u64 = 0,
    count: u64 = 0,
    flag: bool = false,
};

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
    const raw_tokens = try wrapSpans(temporary, projection.raw_tokens);
    const raw_comments = try wrapSpans(temporary, projection.raw_comments);
    const op_values = try temporary.alloc(AbiOp, projection.ops.len);
    const ops = try temporary.alloc(*const AbiOp, projection.ops.len);

    for (projection.ops, op_values, ops) |op, *value, *slot| {
        value.* = .{ .kind = op.kind, .start = op.start, .end = op.end, .count = op.count, .flag = op.flag };
        slot.* = value;
    }

    const request: ProjectionInput = .{
        .source_text = source,
        .raw_tokens = raw_tokens,
        .raw_comments = raw_comments,
        .ops = ops,
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

fn wrapSpans(allocator: std.mem.Allocator, items: []const RawSpan) std.mem.Allocator.Error![]const *const Span {
    const values = try allocator.alloc(Span, items.len);
    const pointers = try allocator.alloc(*const Span, items.len);

    for (items, values, pointers) |item, *value, *slot| {
        value.* = .{ .start = item.start, .end = item.end };
        slot.* = value;
    }

    return pointers;
}
