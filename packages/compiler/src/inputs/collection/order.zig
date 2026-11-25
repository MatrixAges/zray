const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
pub const available = generated;

pub fn positions(allocator: std.mem.Allocator, count: usize) ![]u64 {
    const rows = try allocator.alloc(u64, count);

    for (rows, 0..) |*row, index| row.* = index;

    return rows;
}

pub fn sort(comptime Row: type, backing: std.mem.Allocator, rows: []Row) !void {
    if (rows.len < 2) return;
    if (comptime !generated) return sortSeed(Row, rows);

    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const allocator = scratch.allocator();
    const rule = @import("generated_input_path_order");
    const paths = zx.memory.borrowTextColumn("path", rows);
    const indices = try positions(allocator, rows.len);
    const input: std.meta.Child(rule.Input) = .{ .paths = @ptrCast(&paths), .rows = indices };
    const order = try zx.columns.invoke(rule.executeValue, allocator, &input);

    try apply(Row, rows, @constCast(order));
}

fn apply(comptime Row: type, rows: []Row, order_arg: []u64) !void {
    var order = order_arg;
    const memory = zx.memory;
    const rule = @import("generated_input_path_apply");
    const source = memory.borrowNestedColumn(Row, &.{}, rows);
    var target = memory.borrowNestedWriteColumn(Row, &.{}, rows);
    var scratch: [1]Row = undefined;
    const slot: []Row = &scratch;
    const saved = memory.borrowNestedColumn(Row, &.{}, slot);
    var temporary = memory.borrowNestedWriteColumn(Row, &.{}, slot);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(rule.Input) = .{
        .source = @ptrCast(&source),
        .target = @ptrCast(&target),
        .order = @ptrCast(&order),
        .saved = @ptrCast(&saved),
        .temporary = @ptrCast(&temporary),
        .count = rows.len,
        .width = @sizeOf(Row),
    };

    try zx.columns.invoke(rule.executeValue, empty.allocator(), &input);
}

pub fn select(comptime Row: type, source: []const Row, indices: []const u64, target: []Row) !void {
    if (comptime !generated) {
        for (target, indices) |*row, index| row.* = source[@intCast(index)];

        return;
    }

    const memory = zx.memory;
    const rule = @import("generated_input_row_selection");
    const from = memory.borrowNestedColumn(Row, &.{}, source);
    var to = memory.borrowNestedWriteColumn(Row, &.{}, target);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(rule.Input) = .{
        .source = @ptrCast(&from),
        .target = @ptrCast(&to),
        .indices = indices,
        .width = @sizeOf(Row),
    };

    try zx.columns.invoke(rule.executeValue, empty.allocator(), &input);
}

fn sortSeed(comptime Row: type, rows: []Row) void {
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, left: Row, right: Row) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.less);
}
