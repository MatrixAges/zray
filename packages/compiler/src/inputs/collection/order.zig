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

    try apply(Row, allocator, rows, try allocator.dupe(u64, order));
}

fn apply(comptime Row: type, allocator: std.mem.Allocator, rows: []Row, order: []const u64) !void {
    const rule = @import("generated_input_path_apply");
    const input: std.meta.Child(rule.Input) = .{ .order = order };
    const plan = try zx.columns.invoke(rule.executeValue, allocator, &input);
    var start: usize = 0;

    for (plan.ends) |end_u64| {
        const end: usize = @intCast(end_u64);
        const cycle = plan.indices[start..end];
        const saved = rows[@intCast(cycle[0])];
        var index: usize = 0;

        while (index + 1 < cycle.len) : (index += 1) {
            rows[@intCast(cycle[index])] = rows[@intCast(cycle[index + 1])];
        }

        rows[@intCast(cycle[cycle.len - 1])] = saved;

        start = end;
    }
}

pub fn select(comptime Row: type, backing: std.mem.Allocator, source: []const Row, indices: []const u64, target: []Row) !void {
    if (comptime !generated) {
        for (target, indices) |*row, index| row.* = source[@intCast(index)];

        return;
    }

    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const memory = zx.memory;
    const rule = @import("generated_input_row_selection");
    const from = memory.borrowNestedColumn(Row, &.{}, source);

    const input: std.meta.Child(rule.Input) = .{
        .source = @ptrCast(&from),
        .indices = indices,
        .width = @sizeOf(Row),
    };

    const records = try zx.columns.invoke(rule.executeValue, scratch.allocator(), &input);

    for (records, target) |record, *slot| {
        @memcpy(std.mem.asBytes(slot), record);
    }
}

fn sortSeed(comptime Row: type, rows: []Row) void {
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, left: Row, right: Row) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.less);
}
