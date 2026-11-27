const std = @import("std");
const zx = @import("zx");
const order = @import("order.zig");
const Kind = @import("../collection.zig").Kind;
pub const Document = struct { path: []const u8, text: []const u8, kind: u8 };

pub const Plan = struct {
    source_rows: []const u64,
    module_rows: []const u64,
    template_rows: []const u64,
    sources: usize,
    modules: usize,
};

pub fn prepare(allocator: std.mem.Allocator, files: []const Document) !Plan {
    const indices = try order.positions(allocator, files.len);

    if (comptime !order.available) return try prepareSeed(allocator, files, indices);

    const rule = @import("generated_input_catalog_plan");
    const paths = zx.memory.borrowTextColumn("path", files);
    const kinds = zx.memory.borrowReadColumn(u8, "kind", files);

    const input: std.meta.Child(rule.Input) = .{
        .order = &.{ .paths = @ptrCast(&paths), .rows = indices },
        .kinds = &.{ .rows = @ptrCast(&kinds), .zx = @backingInt(Kind.ZX), .rx = @backingInt(Kind.RX) },
    };

    const result = try zx.columns.invoke(rule.executeValue, allocator, &input);

    return .{
        .source_rows = result.sources,
        .module_rows = result.modules,
        .template_rows = result.templates,
        .sources = result.sources.len,
        .modules = result.modules.len,
    };
}

pub fn publish(files: []const Document, plan: Plan, output: anytype, packages: anytype, attach_templates: bool) !void {
    const Source = std.meta.Child(@TypeOf(output.sources));
    const templates: @FieldType(Source, "templates") = if (attach_templates) output.templates else &.{};

    for (plan.source_rows, output.sources) |row, *slot| {
        const file = files[@intCast(row)];

        slot.* = .{ .path = file.path, .source = file.text, .templates = templates };
    }

    for (plan.module_rows, output.modules) |row, *slot| {
        const file = files[@intCast(row)];

        slot.* = .{ .path = file.path, .source = file.text, .packages = packages };
    }

    for (plan.template_rows, output.templates) |row, *slot| {
        const file = files[@intCast(row)];

        slot.* = .{ .path = file.path, .source = file.text };
    }
}

fn prepareSeed(allocator: std.mem.Allocator, files: []const Document, indices: []u64) !Plan {
    std.mem.sort(u64, indices, files, struct {
        fn less(items: []const Document, left: u64, right: u64) bool {
            return std.mem.lessThan(u8, items[@intCast(left)].path, items[@intCast(right)].path);
        }
    }.less);

    var zxc: usize = 0;
    var rxc: usize = 0;
    var txc: usize = 0;

    for (files) |file| {
        switch (@as(Kind, @fromBackingInt(@intCast(file.kind)))) {
            .ZX => zxc += 1,
            .RX => rxc += 1,
            .Template => txc += 1,
            .Ignored => unreachable,
        }
    }

    const source_rows = try allocator.alloc(u64, zxc);
    const module_rows = try allocator.alloc(u64, rxc);
    const template_rows = try allocator.alloc(u64, txc);
    var si: usize = 0;
    var mi: usize = 0;
    var ti: usize = 0;

    for (indices) |row| {
        switch (@as(Kind, @fromBackingInt(@intCast(files[@intCast(row)].kind)))) {
            .ZX => {
                source_rows[si] = row;
                si += 1;
            },
            .RX => {
                module_rows[mi] = row;
                mi += 1;
            },
            .Template => {
                template_rows[ti] = row;
                ti += 1;
            },
            .Ignored => unreachable,
        }
    }

    return .{
        .source_rows = source_rows,
        .module_rows = module_rows,
        .template_rows = template_rows,
        .sources = zxc,
        .modules = rxc,
    };
}
