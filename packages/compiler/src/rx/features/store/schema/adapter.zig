const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../../checks.zig");
const tree = @import("../../../schema/tree/adapter.zig");
pub const supports = tree.supports;

pub const Groups = struct {
    first: usize,
    starts: []const u32,
    next: []const ?u32,
    offsets: ?[]const u64 = null,
    pub fn singleton(first: usize) Groups {
        return .{ .first = first, .starts = &.{0}, .next = &.{null} };
    }
};

pub fn validate(allocator: std.mem.Allocator, children: anytype, node: anytype, reporter: *dsl.Reporter) dsl.Error!Groups {
    if (children.len == 1 and children[0] == .object) return .singleton(0);
    if (children.len > std.math.maxInt(u32)) return error.OutOfMemory;

    var buffer: [1024]u8 align(@alignOf(u64)) = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());

    defer arena.deinit();

    const temporary = arena.allocator();
    const rule = @import("generated_rx_store_schema");
    var buckets: []u64 = &.{};
    var input: std.meta.Child(rule.Input) = undefined;

    input.workspace = &.{ .allocator = @ptrCast(&temporary), .buckets = @ptrCast(&buckets) };

    const result = try tree.invoke(rule, temporary, node, &input);

    switch (result.issue) {
        .None => {
            const first: usize = @intCast(result.first);

            if (result.objects == 1) return .singleton(first);

            return .{
                .first = first,
                .starts = try allocator.dupe(u32, result.starts),
                .next = try allocator.dupe(?u32, result.next),
                .offsets = try allocator.dupe(u64, result.offsets),
            };
        },
        .DuplicateType => return checks.fail(tree.at(node, result.where.?), "as", "Duplicate RX declaration", reporter),
        .LateType => return checks.fail(tree.at(node, result.where.?), "from", "Type declarations must precede Store objects", reporter),
        .MissingObject => return checks.fail(node, "", "Store requires at least one Object", reporter),
        .DuplicateField => return checks.fail(tree.at(node, result.where.?), "name", "Store object field path is already declared", reporter),
    }
}

pub fn uniqueFields(allocator: std.mem.Allocator, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const count = node.childCount();

    if (count < 2) return;
    if (count > std.math.maxInt(u32)) return error.OutOfMemory;

    const found = try tree.run(@import("generated_rx_store_unique"), allocator, node) orelse return;

    return checks.fail(tree.at(node, found), "name", "Duplicate RX declaration", reporter);
}
