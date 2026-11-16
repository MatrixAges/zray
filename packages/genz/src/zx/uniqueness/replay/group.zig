const std = @import("std");
const zx = @import("zx");

pub fn build(allocator: std.mem.Allocator, first: []u32, owners: []const u32) std.mem.Allocator.Error![]const u32 {
    @memset(first, 0);

    if (!@import("genz_options").generated_analysis) return seed(allocator, first, owners);

    const entry = @import("generated_uniqueness_group");
    const Input = std.meta.Child(entry.Input);
    const input: Input = .{ .count = first.len - 1, .owners = owners, .first = @ptrCast(&first) };

    return zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("replay visit grouping failed: {s}", .{@errorName(err)}),
    };
}

fn seed(allocator: std.mem.Allocator, first: []u32, owners: []const u32) std.mem.Allocator.Error![]const u32 {
    const items = try allocator.alloc(u32, owners.len);

    for (owners) |body| first[body] += 1;
    for (1..first.len) |index| first[index] += first[index - 1];

    var index = owners.len;

    while (index != 0) {
        index -= 1;
        const body = owners[index];
        first[body] -= 1;
        items[first[body]] = @intCast(index);
    }

    return items;
}
