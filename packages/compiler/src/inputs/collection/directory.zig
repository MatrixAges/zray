const std = @import("std");
const inputs = @import("../collection.zig");
const zx = @import("zx");
const memory = zx.memory;
const generated = @import("parser_options").generated_parser;

pub const File = struct {
    kind: inputs.Kind,
    path: []const u8,
    relative: []const u8,
    lookup: bool,
    retain: bool,
};

pub const Schedule = struct { next: []const []const u8, files: usize };

pub fn file(allocator: std.mem.Allocator, base: []const u8, name: []const u8, prefix_length: usize, lookup_limit: usize) !?File {
    if (comptime !generated) {
        const selected = inputs.kind(name);

        if (selected == .Ignored) return null;

        const path = try std.mem.concat(allocator, u8, &.{ base, name });

        return .{
            .kind = selected,
            .path = path,
            .relative = path[prefix_length..],
            .lookup = path.len <= lookup_limit,
            .retain = selected != .RX,
        };
    }

    const rule = @import("generated_input_directory_file");
    var storage: [1]File = undefined;
    const output: []File = &storage;
    const Input = std.meta.Child(rule.Input);

    const columns = memory.borrowWriteFields(.{
        .paths = "path",
        .relatives = "relative",
        .lookup = "lookup",
        .retain = "retain",
    }, output);

    const request: std.meta.Child(rule.Input) = .{
        .prefix = base,
        .name = name,
        .prefix_length = prefix_length,
        .lookup_limit = lookup_limit,
        .output = &columns.bind(std.meta.Child(@FieldType(Input, "output"))),
    };

    const selected = try zx.columns.invoke(rule.executeValue, allocator, &request);

    if (selected == .Ignored) return null;

    storage[0].kind = @fromBackingInt(@intCast(@backingInt(selected)));

    return storage[0];
}

pub fn seedSchedule(allocator: std.mem.Allocator, parents: []const []const u8, listings: anytype) !Schedule {
    var next: std.ArrayList([]const u8) = .empty;
    var files: usize = 0;

    for (parents, listings) |parent, listing| {
        files += listing.files.len;

        for (listing.directories) |name| try next.append(allocator, try inputs.qualify(allocator, "", parent, name));
    }

    return .{ .next = next.items, .files = files };
}

pub fn seedFlatten(allocator: std.mem.Allocator, listings: anytype, entries: anytype, prefix_length: usize, copy_paths: bool) !void {
    var next: usize = 0;

    for (listings) |listing| {
        const output = entries[next..][0..listing.files.len];

        @memcpy(output, listing.files);

        if (copy_paths) for (output) |*item| {
            item.path = try allocator.dupe(u8, item.path);
            item.relative = item.path[prefix_length..];
        };

        next += output.len;
    }
}
