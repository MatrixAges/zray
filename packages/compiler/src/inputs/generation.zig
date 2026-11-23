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

    var result: Stamp = undefined;
    var writer = std.Io.Writer.fixed(&result);
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const rule = @import("generated_generation_stamp");

    const input: std.meta.Child(rule.Input) = .{
        .out = @ptrCast(&writer),
        .digest = digest,
    };

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    std.debug.assert(writer.end == result.len);

    return result;
}

pub fn entries(source: anytype, roots: [][]const u8, exports: anytype) void {
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
    const root_paths = memory.borrowNestedWriteColumn([]const u8, &.{}, roots);
    const export_paths = memory.borrowWriteColumn([]const u8, "path", exports);
    const export_names = memory.borrowWriteColumn([]const u8, "name", exports);
    const rule = @import("generated_generation_entries");
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(rule.Input) = .{
        .paths = @ptrCast(&paths),
        .names = @ptrCast(&names),
        .roots = @ptrCast(&root_paths),
        .export_paths = @ptrCast(&export_paths),
        .export_names = @ptrCast(&export_names),
        .count = source.len,
    };

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
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
    var buffer: [settings.summary_capacity]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .out = @ptrCast(&writer),
        .counts = &values,
        .durations = &.{ .infer = durations.infer, .emit = durations.emit, .write = durations.write },
    };

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return allocator.dupe(u8, writer.buffered());
}
