const std = @import("std");
const zx = @import("zx");
const Self = @This();

expressions: []const u64 = &.{},
blocks: []const u64 = &.{},
statements: []const u64 = &.{},
patterns: []const u64 = &.{},
edges: []const u64 = &.{},
pub fn create(allocator: std.mem.Allocator, storage: anytype) std.mem.Allocator.Error!Self {
    return (try prepare(allocator, storage)).order;
}

const Prepared = struct { order: Self = .{}, words: []const u64 = &.{} };

pub fn prepare(allocator: std.mem.Allocator, storage: anytype) std.mem.Allocator.Error!Prepared {
    const size = @import("generated_syntax_order_size");
    const build = @import("generated_syntax_order_build");
    const Build = std.meta.Child(build.Input);
    const Trees = std.meta.Child(@FieldType(Build, "trees"));

    const trees: Trees = .{
        .expressions = zx.columns.pointer(@FieldType(Trees, "expressions"), storage.expressions),
        .blocks = zx.columns.pointer(@FieldType(Trees, "blocks"), storage.blocks),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const count = zx.columns.invoke(size.executeValue, empty.allocator(), &trees) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (count == 0) return .{};

    const lengths = [_]usize{ storage.expressions.nodes.len, storage.blocks.blocks.len, storage.blocks.statements.len, storage.blocks.names.len };
    const edge_count = std.math.cast(usize, count) orelse return error.OutOfMemory;
    var total = edge_count;

    for (lengths) |length| total = std.math.add(usize, total, length) catch return error.OutOfMemory;

    const writable = try allocator.alloc(u64, total);
    var remaining = writable;
    var expressions = take(&remaining, lengths[0]);
    var blocks = take(&remaining, lengths[1]);
    var statements = take(&remaining, lengths[2]);
    var patterns = take(&remaining, lengths[3]);

    const input: Build = .{
        .trees = &trees,
        .columns = &.{
            .expressions = @ptrCast(&expressions),
            .blocks = @ptrCast(&blocks),
            .statements = @ptrCast(&statements),
            .patterns = @ptrCast(&patterns),
            .edges = @ptrCast(&remaining),
        },
    };

    const written = zx.columns.invoke(build.executeValue, empty.allocator(), &input) catch unreachable;

    std.debug.assert(written == edge_count);

    return .{
        .order = .{ .expressions = expressions, .blocks = blocks, .statements = statements, .patterns = patterns, .edges = remaining },
        .words = writable,
    };
}

pub fn borrow(words: []const u64, storage: anytype) Self {
    if (words.len == 0) return .{};

    const blocks = storage.expressions.nodes.len;
    const statements = blocks + storage.blocks.blocks.len;
    const patterns = statements + storage.blocks.statements.len;
    const edges = patterns + storage.blocks.names.len;

    return .{
        .expressions = words[0..blocks],
        .blocks = words[blocks..statements],
        .statements = words[statements..patterns],
        .patterns = words[patterns..edges],
        .edges = words[edges..],
    };
}

fn take(remaining: *[]u64, length: usize) []u64 {
    const result = remaining.*[0..length];
    remaining.* = remaining.*[length..];

    return result;
}
