const std = @import("std");
const zx = @import("zx");
const order = @import("order.zig");
const Kind = @import("../collection.zig").Kind;
pub const Document = struct { path: []const u8, text: []const u8, kind: u8 };

pub const Plan = struct {
    sources: []const u64,
    modules: []const u64,
    templates: []const u64,
};

pub fn prepare(allocator: std.mem.Allocator, files: []const Document) !Plan {
    const indices = try order.positions(allocator, files.len);

    if (comptime !order.available) return prepareSeed(allocator, files, indices);

    const rule = @import("generated_input_catalog_plan");
    const paths = zx.memory.borrowTextColumn("path", files);
    const kinds = zx.memory.borrowReadColumn(u8, "kind", files);
    const target = try allocator.alloc(u64, files.len);

    const input: std.meta.Child(rule.Input) = .{
        .order = &.{ .paths = @ptrCast(&paths), .rows = indices },
        .layout = &.{
            .kinds = &.{ .rows = @ptrCast(&kinds), .zx = @backingInt(Kind.ZX), .rx = @backingInt(Kind.RX) },
            .target = @ptrCast(&target),
        },
    };

    const counts = try zx.columns.invoke(rule.executeValue, allocator, &input);

    return ranges(target, @intCast(counts.zx), @intCast(counts.rx));
}

fn ranges(rows: []const u64, zxc: usize, rxc: usize) Plan {
    return .{ .sources = rows[0..zxc], .modules = rows[zxc..][0..rxc], .templates = rows[zxc + rxc ..] };
}

fn prepareSeed(allocator: std.mem.Allocator, files: []const Document, indices: []u64) !Plan {
    std.mem.sort(u64, indices, files, struct {
        fn less(items: []const Document, left: u64, right: u64) bool {
            return std.mem.lessThan(u8, items[@intCast(left)].path, items[@intCast(right)].path);
        }
    }.less);

    const target = try allocator.alloc(u64, files.len);
    var index: usize = 0;
    var zxc: usize = 0;
    var rxc: usize = 0;

    for ([_]Kind{ .ZX, .RX, .Template }) |kind| {
        const start = index;

        for (indices) |row| {
            if (files[@intCast(row)].kind != @backingInt(kind)) continue;

            target[index] = row;
            index += 1;
        }

        if (kind == .ZX) zxc = index - start;
        if (kind == .RX) rxc = index - start;
    }

    return ranges(target, zxc, rxc);
}
