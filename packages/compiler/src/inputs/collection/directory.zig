const std = @import("std");
const inputs = @import("../collection.zig");
const zx = @import("zx");
const memory = zx.memory;
const generated = @import("parser_options").generated_parser;
pub const File = struct { kind: inputs.Kind, path: []const u8 };
pub const Probe = struct { lookup: bool, retain: bool };
pub const Schedule = struct { next: []const []const u8, files: usize };

pub fn file(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) !?File {
    if (comptime !generated) {
        const selected = inputs.kind(name);

        return if (selected == .Ignored) null else .{
            .kind = selected,
            .path = try std.mem.concat(allocator, u8, &.{ prefix, name }),
        };
    }

    const rule = @import("generated_input_directory_file");
    var storage: [1][]const u8 = undefined;
    var output: []const []const u8 = &storage;
    const request: std.meta.Child(rule.Input) = .{ .prefix = prefix, .name = name, .path = @ptrCast(&output) };
    const selected = try zx.columns.invoke(rule.executeValue, allocator, &request);

    return if (selected == .Ignored) null else .{ .kind = @fromBackingInt(@intCast(@backingInt(selected))), .path = storage[0] };
}

pub fn probe(selected: inputs.Kind, length: usize, limit: usize) Probe {
    if (comptime !generated) return .{ .lookup = length <= limit, .retain = selected != .RX };

    const rule = @import("generated_input_directory_probe");
    var buffer: [128]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const request: std.meta.Child(rule.Input) = .{ .kind = @fromBackingInt(@intCast(@backingInt(selected))), .length = length, .limit = limit };
    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &request) catch unreachable;

    return .{ .lookup = result.lookup, .retain = result.retain };
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

fn seedSchedule(allocator: std.mem.Allocator, parents: []const []const u8, listings: anytype) !Schedule {
    var next: std.ArrayList([]const u8) = .empty;
    var files: usize = 0;

    for (parents, listings) |parent, listing| {
        files += listing.files.len;

        for (listing.directories) |name| try next.append(allocator, try inputs.qualify(allocator, "", parent, name));
    }

    return .{ .next = next.items, .files = files };
}
