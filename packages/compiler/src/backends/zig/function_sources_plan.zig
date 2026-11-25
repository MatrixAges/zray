const std = @import("std");
const zx = @import("zx");
const Cache = @import("cache.zig");
const rule = @import("generated_function_sources_plan");
const Input = std.meta.Child(rule.Input);
const Output = @typeInfo(@typeInfo(@TypeOf(rule.executeValue)).@"fn".return_type.?).error_union.payload;
const Lookup = std.meta.Child(@typeInfo(@FieldType(Input, "lookup")).optional.child);

pub const Plan = struct {
    reused: []const u64,
    pending: []const u64,
    offsets: []const u64,
    size: usize,
    stored: []const u64 = &.{},
    held: usize = 0,
    discarded: usize = 0,
    failures: usize = 0,
    last_failure: ?usize = null,
    ordered: bool = false,
};

pub fn create(allocator: std.mem.Allocator, fetched: []const Cache.Fetched, cached: *const Cache) std.mem.Allocator.Error!Plan {
    if (comptime !@import("parser_options").generated_parser) return @import("function_sources_seed.zig").create(allocator, fetched);

    const count = fetched.len;
    const capacity = std.math.mul(usize, count, 3) catch return error.OutOfMemory;
    const rows = try allocator.alloc(u64, capacity);
    var reused = rows[0..count];
    var pending = rows[count..][0..count];
    var offsets = rows[count * 2 ..];
    const sources = zx.memory.borrowReadColumn(?[]u8, "source", fetched);
    const kinds = zx.memory.borrowReadColumn(Cache.Fetched.Kind, "kind", fetched);
    const Disk = std.meta.Child(@typeInfo(@FieldType(Lookup, "disk")).optional.child);

    const disk: Disk = .{
        .kinds = @ptrCast(&kinds),
        .stored = @backingInt(Cache.Fetched.Kind.stored),
        .invalid = @backingInt(Cache.Fetched.Kind.invalid),
        .failed = @backingInt(Cache.Fetched.Kind.failed),
        .writer_active = cached.writer != null,
    };

    const lookup: Lookup = .{
        .disk = if (cached.storage != null) &disk else null,
        .reused = @ptrCast(&reused),
        .pending = @ptrCast(&pending),
    };

    const output = try run(.{ .count = count, .sources = @ptrCast(&sources), .offsets = @ptrCast(&offsets), .lookup = &lookup });
    const hits: usize = @intCast(output.reused);

    return .{
        .reused = reused[0..hits],
        .pending = pending[0..@intCast(output.pending)],
        .offsets = offsets[0..hits],
        .size = std.math.cast(usize, output.size) orelse return error.OutOfMemory,
        .stored = pending[count - @as(usize, @intCast(output.stored)) ..],
        .held = @intCast(output.held),
        .discarded = @intCast(output.discarded),
        .failures = @intCast(output.failures),
        .last_failure = if (output.last_failure) |index| @intCast(index) else null,
        .ordered = output.ordered,
    };
}

pub fn layout(sources: *const zx.memory.ReadColumn, offsets_arg: []u64) std.mem.Allocator.Error!usize {
    var offsets = offsets_arg;
    const output = try run(.{ .count = offsets.len, .sources = @ptrCast(sources), .offsets = @ptrCast(&offsets), .lookup = null });

    if (output.pending != 0) unreachable;

    return std.math.cast(usize, output.size) orelse error.OutOfMemory;
}

fn run(input: Input) std.mem.Allocator.Error!Output {
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
