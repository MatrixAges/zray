const std = @import("std");
const zx = @import("zx");
const order = @import("order.zig");
const Kind = @import("../collection.zig").Kind;
pub const Document = struct { path: []const u8, text: []const u8, kind: u8 };

pub const Plan = struct {
    ordered: []const u64,
    sources: usize,
    modules: usize,
};

pub fn prepare(allocator: std.mem.Allocator, files: []const Document) !Plan {
    const indices = try order.positions(allocator, files.len);

    if (comptime !order.available) return prepareSeed(files, indices);

    const rule = @import("generated_input_catalog_plan");
    const paths = zx.memory.borrowTextColumn("path", files);
    const kinds = zx.memory.borrowReadColumn(u8, "kind", files);

    const input: std.meta.Child(rule.Input) = .{
        .order = &.{ .paths = @ptrCast(&paths), .rows = indices },
        .kinds = &.{ .rows = @ptrCast(&kinds), .zx = @backingInt(Kind.ZX), .rx = @backingInt(Kind.RX) },
    };

    const result = try zx.columns.invoke(rule.executeValue, allocator, &input);

    return .{ .ordered = result.ordered, .sources = @intCast(result.counts.zx), .modules = @intCast(result.counts.rx) };
}

pub fn publish(files: []const Document, plan: Plan, output: anytype, packages: anytype, attach_templates: bool) !void {
    const Source = std.meta.Child(@TypeOf(output.sources));
    const Module = std.meta.Child(@TypeOf(output.modules));
    const templates: @FieldType(Source, "templates") = if (attach_templates) output.templates else &.{};
    const original: @FieldType(Source, "original") = null;
    const origins: @FieldType(Source, "template_origins") = &.{};

    if (comptime !order.available) {
        var zxc: usize = 0;
        var rxc: usize = 0;
        var resources: usize = 0;

        for (plan.ordered) |row| {
            const file = files[@intCast(row)];

            switch (@as(Kind, @fromBackingInt(@intCast(file.kind)))) {
                .ZX => {
                    output.sources[zxc] = .{ .path = file.path, .source = file.text, .templates = templates };
                    zxc += 1;
                },
                .RX => {
                    output.modules[rxc] = .{ .path = file.path, .source = file.text, .packages = packages };
                    rxc += 1;
                },
                .Template => {
                    output.templates[resources] = .{ .path = file.path, .source = file.text };
                    resources += 1;
                },
                .Ignored => unreachable,
            }
        }

        return;
    }

    const memory = zx.memory;
    const rule = @import("generated_input_catalog_publish");
    const paths = memory.borrowTextColumn("path", files);
    const bodies = memory.borrowTextColumn("text", files);
    const kinds = memory.borrowReadColumn(u8, "kind", files);
    const Input = std.meta.Child(rule.Input);
    const Text = std.meta.Child(@FieldType(Input, "templates"));
    const text = .{ .paths = "path", .bodies = "source" };
    const source_text = memory.borrowWriteFields(text, output.sources);
    const module_text = memory.borrowWriteFields(text, output.modules);
    const resource_text = memory.borrowWriteFields(text, output.templates);
    const source_templates = memory.borrowWriteColumn(@TypeOf(templates), "templates", output.sources);
    const source_original = memory.borrowWriteColumn(?[]const u8, "original", output.sources);
    const source_origins = memory.borrowWriteColumn(@TypeOf(origins), "template_origins", output.sources);
    const module_packages = memory.borrowWriteColumn(@FieldType(Module, "packages"), "packages", output.modules);
    const attached_packages: @FieldType(Module, "packages") = packages;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(rule.Input) = .{
        .paths = @ptrCast(&paths),
        .bodies = @ptrCast(&bodies),
        .kinds = &.{ .rows = @ptrCast(&kinds), .zx = @backingInt(Kind.ZX), .rx = @backingInt(Kind.RX) },
        .ordered = plan.ordered,
        .sources = &.{
            .text = &source_text.bind(Text),
            .templates = @ptrCast(&source_templates),
            .original = @ptrCast(&source_original),
            .origins = @ptrCast(&source_origins),
        },
        .modules = &.{
            .text = &module_text.bind(Text),
            .packages = @ptrCast(&module_packages),
        },
        .templates = &resource_text.bind(Text),
        .shared = &.{
            .templates = std.mem.asBytes(&templates),
            .packages = std.mem.asBytes(&attached_packages),
            .original = std.mem.asBytes(&original),
            .origins = std.mem.asBytes(&origins),
        },
    };

    try zx.columns.invoke(rule.executeValue, empty.allocator(), &input);
}

fn prepareSeed(files: []const Document, indices: []u64) Plan {
    std.mem.sort(u64, indices, files, struct {
        fn less(items: []const Document, left: u64, right: u64) bool {
            return std.mem.lessThan(u8, items[@intCast(left)].path, items[@intCast(right)].path);
        }
    }.less);

    var zxc: usize = 0;
    var rxc: usize = 0;

    for (files) |file| {
        switch (@as(Kind, @fromBackingInt(@intCast(file.kind)))) {
            .ZX => zxc += 1,
            .RX => rxc += 1,
            .Template => {},
            .Ignored => unreachable,
        }
    }

    return .{ .ordered = indices, .sources = zxc, .modules = rxc };
}
