const std = @import("std");
const zx = @import("zx");

pub fn build(comptime Row: type, first: []u32, owners: []const u32, source: []const Row, target: []Row) std.mem.Allocator.Error!void {
    @memset(first, 0);

    if (!@import("genz_options").generated_analysis) return seed(Row, first, owners, source, target);

    std.debug.assert(source.len == owners.len and target.len == owners.len);

    const entry = @import("generated_uniqueness_group");
    const Input = std.meta.Child(entry.Input);
    const output = std.mem.sliceAsBytes(target);

    const input: Input = .{
        .count = first.len - 1,
        .owners = owners,
        .first = @ptrCast(&first),
        .source = std.mem.sliceAsBytes(source),
        .target = @ptrCast(&output),
        .width = @sizeOf(Row),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("replay visit grouping failed: {s}", .{@errorName(err)}),
    };
}

fn seed(comptime Row: type, first: []u32, owners: []const u32, source: []const Row, target: []Row) void {
    for (owners) |body| first[body] += 1;
    for (1..first.len) |index| first[index] += first[index - 1];

    var index = owners.len;

    while (index != 0) {
        index -= 1;
        const body = owners[index];
        first[body] -= 1;
        target[first[body]] = source[index];
    }
}
