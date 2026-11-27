const std = @import("std");
const zx = @import("zx");
const Digest = @import("fingerprint.zig").Digest;
pub const generated = @import("parser_options").generated_parser;

const settings = if (generated) @import("generated_generation_constants").@"zx.constants" else struct {
    pub const stamp_name = ".zxc-inputs";
    pub const stamp_width = @sizeOf(Digest) * 2;
};

pub const stamp_name = settings.stamp_name;
pub const stamp_width = settings.stamp_width;
pub const Stamp = [stamp_width]u8;

pub fn stamp(digest: *const Digest) Stamp {
    if (comptime !generated) return std.fmt.bytesToHex(digest.*, .lower);

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const rule = @import("generated_generation_stamp");
    const text = rule.executeValue(scratch.allocator(), digest) catch unreachable;

    std.debug.assert(text.len == stamp_width);

    return text[0..stamp_width].*;
}

pub fn entries(allocator: std.mem.Allocator, source: anytype, roots: [][]const u8, exports: anytype) void {
    if (comptime !generated) {
        for (source, roots, exports) |entry, *root, *exported| {
            root.* = entry.path;
            exported.* = .{ .name = entry.name, .path = entry.path };
        }

        return;
    }

    const memory = zx.memory;
    const paths = memory.borrowTextColumn("path", source);
    const names = memory.borrowTextColumn("name", source);
    const rule = @import("generated_generation_entries");
    var buffer: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const input: std.meta.Child(rule.Input) = .{
        .paths = @ptrCast(&paths),
        .names = @ptrCast(&names),
        .count = source.len,
    };

    const rows = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    for (rows, roots, exports) |row, *root, *exported| {
        root.* = row.path;
        exported.* = .{ .name = row.name, .path = row.path };
    }
}

pub const Counts = struct {
    entries: u64,
    analyzed: u64,
    reused: u64,
    bodies_only: bool,
    files: u64,
    generated: u64,
    cached: u64,
};

pub const Durations = struct { infer: u64, emit: u64, write: u64 };

pub fn report(allocator: std.mem.Allocator, counts: Counts, durations: Durations) ![]const u8 {
    if (comptime !generated) return std.fmt.allocPrint(allocator, "bootstrap: {d} entries, {d} modules analyzed, {d} reused{s}, {d} function files, {d} generated, {d} reused; infer {d}ms, emit {d}ms, write {d}ms\n", .{
        counts.entries, counts.analyzed,  counts.reused, if (counts.bodies_only) " (bodies only)" else "",
        counts.files,   counts.generated, counts.cached, durations.infer,
        durations.emit, durations.write,
    });

    const rule = @import("generated_generation_report");
    const Input = std.meta.Child(rule.Input);
    const values = zx.columns.view(std.meta.Child(@FieldType(Input, "counts")), &counts);
    var buffer: [1024]u8 = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(backing.allocator());

    defer arena.deinit();

    const input: Input = .{
        .counts = &values,
        .durations = &.{ .infer = durations.infer, .emit = durations.emit, .write = durations.write },
    };

    const summary = try rule.executeIn(arena.allocator(), &input);

    return allocator.dupe(u8, summary);
}
