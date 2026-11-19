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
    const paths = memory.borrowWriteColumn([]const u8, "path", output);
    const relatives = memory.borrowWriteColumn([]const u8, "relative", output);
    const lookup = memory.borrowWriteColumn(bool, "lookup", output);
    const retain = memory.borrowWriteColumn(bool, "retain", output);

    const request: std.meta.Child(rule.Input) = .{
        .prefix = base,
        .name = name,
        .prefix_length = prefix_length,
        .lookup_limit = lookup_limit,
        .output = &.{
            .paths = @ptrCast(&paths),
            .relatives = @ptrCast(&relatives),
            .lookup = @ptrCast(&lookup),
            .retain = @ptrCast(&retain),
        },
    };

    const selected = try zx.columns.invoke(rule.executeValue, allocator, &request);

    if (selected == .Ignored) return null;

    storage[0].kind = @fromBackingInt(@intCast(@backingInt(selected)));

    return storage[0];
}

pub fn schedule(allocator: std.mem.Allocator, parents: []const []const u8, listings: anytype) !Schedule {
    if (comptime !generated) return seedSchedule(allocator, parents, listings);

    const rule = @import("generated_input_directory_schedule");
    const directories = memory.borrowReadColumn([]const []const u8, "directories", listings);
    const files = memory.borrowListColumn([]const u8, "files", "path", listings);
    var next: []const []const u8 = &.{};

    const request: std.meta.Child(rule.Input) = .{
        .level = &.{ .parents = parents, .directories = @ptrCast(&directories), .files = @ptrCast(&files) },
        .next = @ptrCast(&next),
    };

    const count = try zx.columns.invoke(rule.executeValue, allocator, &request);

    return .{ .next = next, .files = @intCast(count) };
}

pub fn flatten(allocator: std.mem.Allocator, listings: anytype, entries: anytype, prefix_length: usize, copy_paths: bool) !void {
    if (comptime !generated) {
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

        return;
    }

    const rule = @import("generated_input_directory_flatten");
    const files = memory.borrowSliceColumn(&.{"files"}, listings);
    const paths = memory.borrowListColumn([]const u8, "files", "path", listings);
    const target_paths = memory.borrowWriteColumn([]const u8, "path", entries);
    const target_relatives = memory.borrowWriteColumn([]const u8, "relative", entries);
    const records = std.mem.sliceAsBytes(entries);

    const request: std.meta.Child(rule.Input) = .{
        .files = @ptrCast(&files),
        .paths = @ptrCast(&paths),
        .entries = @ptrCast(&records),
        .target_paths = @ptrCast(&target_paths),
        .target_relatives = @ptrCast(&target_relatives),
        .groups = listings.len,
        .width = @sizeOf(std.meta.Child(@TypeOf(entries))),
        .prefix_length = prefix_length,
        .copy_paths = copy_paths,
    };

    try zx.columns.invoke(rule.executeValue, allocator, &request);
}

fn seedSchedule(allocator: std.mem.Allocator, parents: []const []const u8, listings: anytype) !Schedule {
    var next: std.ArrayList([]const u8) = .empty;
    var files: usize = 0;

    for (parents, listings) |parent, listing| {
        files += listing.files.len;

        for (listing.directories) |name| try next.append(allocator, try inputs.qualify(allocator, "", parent, name));
    }

    return .{ .next = next.items, .files = files };
}
