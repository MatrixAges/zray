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

    apply(Row, rows, @constCast(order));
}

fn apply(comptime Row: type, rows: []Row, order: []u64) void {
    for (order, 0..) |source, start| {
        if (source == start) continue;

        const saved = rows[start];
        var target = start;

        while (true) {
            const next: usize = @intCast(order[target]);

            order[target] = target;

            if (next == start) break;

            rows[target] = rows[next];
            target = next;
        }

        rows[target] = saved;
    }
}

fn sortSeed(comptime Row: type, rows: []Row) void {
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, left: Row, right: Row) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.less);
}
