const std = @import("std");
const zx = @import("zx");
const Cache = @import("cache.zig");
const rule = @import("generated_function_sources_plan");
const Input = std.meta.Child(rule.Input);
const Output = @typeInfo(@typeInfo(@TypeOf(rule.executeValue)).@"fn".return_type.?).error_union.payload;
const Disk = std.meta.Child(@typeInfo(@FieldType(Input, "disk")).optional.child);

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

pub const Layout = struct {
    offsets: []const u64,
    size: usize,
};

pub fn create(allocator: std.mem.Allocator, fetched: []const Cache.Fetched, cached: *const Cache) std.mem.Allocator.Error!Plan {
    if (comptime !@import("parser_options").generated_parser) return @import("function_sources_seed.zig").create(allocator, fetched);

    const sources = zx.memory.borrowReadColumn(?[]u8, "source", fetched);
    const kinds = zx.memory.borrowReadColumn(Cache.Fetched.Kind, "kind", fetched);

    const disk: Disk = .{
        .kinds = @ptrCast(&kinds),
        .stored = @backingInt(Cache.Fetched.Kind.stored),
        .invalid = @backingInt(Cache.Fetched.Kind.invalid),
        .failed = @backingInt(Cache.Fetched.Kind.failed),
        .writer_active = cached.writer != null,
    };

    const output = try run(allocator, .{
        .count = fetched.len,
        .sources = @ptrCast(&sources),
        .collect_lookup = true,
        .disk = if (cached.storage != null) &disk else null,
    });

    return .{
        .reused = output.reused,
        .pending = output.pending,
        .offsets = output.offsets,
        .size = std.math.cast(usize, output.size) orelse return error.OutOfMemory,
        .stored = output.stored,
        .held = @intCast(output.held),
        .discarded = @intCast(output.discarded),
        .failures = @intCast(output.failures),
        .last_failure = if (output.last_failure) |index| @intCast(index) else null,
        .ordered = output.ordered,
    };
}

pub fn layout(allocator: std.mem.Allocator, sources: *const zx.memory.ReadColumn, count: usize) std.mem.Allocator.Error!Layout {
    const output = try run(allocator, .{
        .count = count,
        .sources = @ptrCast(sources),
        .collect_lookup = false,
        .disk = null,
    });

    if (output.pending_count != 0) unreachable;

    return .{
        .offsets = output.offsets,
        .size = std.math.cast(usize, output.size) orelse return error.OutOfMemory,
    };
}

fn run(allocator: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Output {
    return zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
