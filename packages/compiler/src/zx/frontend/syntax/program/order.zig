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
    const build = @import("generated_syntax_order_build");
    const Trees = std.meta.Child(build.Input);

    const trees: Trees = .{
        .expressions = zx.columns.pointer(@FieldType(Trees, "expressions"), storage.expressions),
        .blocks = zx.columns.pointer(@FieldType(Trees, "blocks"), storage.blocks),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var scratch_buf: [2048]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const built = zx.columns.invoke(build.executeValue, fallback.allocator(), &trees) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (built.edges.len == 0) return .{};

    const lengths = [_]usize{
        built.expressions.len,
        built.blocks.len,
        built.statements.len,
        built.patterns.len,
        built.edges.len,
    };

    var total: usize = 0;

    for (lengths) |length| total = std.math.add(usize, total, length) catch return error.OutOfMemory;

    const writable = try allocator.alloc(u64, total);
    var remaining = writable;
    const expressions = take(&remaining, lengths[0]);
    const blocks = take(&remaining, lengths[1]);
    const statements = take(&remaining, lengths[2]);
    const patterns = take(&remaining, lengths[3]);
    const edges = take(&remaining, lengths[4]);

    @memcpy(expressions, built.expressions);
    @memcpy(blocks, built.blocks);
    @memcpy(statements, built.statements);
    @memcpy(patterns, built.patterns);
    @memcpy(edges, built.edges);

    return .{
        .order = .{ .expressions = expressions, .blocks = blocks, .statements = statements, .patterns = patterns, .edges = edges },
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
