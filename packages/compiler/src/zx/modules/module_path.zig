const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;

pub fn index(allocator: std.mem.Allocator, candidate: []const u8) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(std.mem.endsWith(u8, candidate, ".zx"));

    return indexFor(allocator, candidate[0 .. candidate.len - ".zx".len], false);
}

pub fn select(allocator: std.mem.Allocator, candidate: []const u8, known: anytype) ![]const u8 {
    if (try known.has(candidate)) return candidate;
    if (!std.mem.endsWith(u8, candidate, ".zx")) return candidate;

    const fallback = try index(allocator, candidate);

    errdefer allocator.free(fallback);

    if (try known.has(fallback)) return fallback;

    allocator.free(fallback);

    return candidate;
}

pub fn callMember(reference: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(reference);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;

    if (std.mem.endsWith(u8, reference, "/")) return null;

    if (comptime generated) {
        const rule = @import("generated_module_call_member");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const start = rule.executeValue(empty.allocator(), name) catch unreachable;

        return if (start) |offset| name[@intCast(offset)..] else null;
    }

    if (dot == 0 or dot + 1 == name.len) return null;
    if (std.mem.eql(u8, name[0..dot], ".") or std.mem.eql(u8, name[0..dot], "..")) return null;

    for ([_][]const u8{ ".zx", ".rx", ".zig" }) |suffix| {
        if (std.mem.eql(u8, name[dot..], suffix)) return null;
    }

    return name[dot + 1 ..];
}

pub const CallSource = struct { path: []const u8, named: bool };

/// The candidate is the normalized file path for the complete dotted spelling.
pub fn selectQualified(allocator: std.mem.Allocator, candidate: []const u8, member: []const u8, known: anytype) !CallSource {
    if (comptime generated and @TypeOf(known) == @import("source_index.zig").Known) {
        const selected = try @import("path/selection.zig").select(allocator, candidate, known.paths, member.len);

        if (known.matched_row) |row| row.* = selected.row;

        return .{ .path = selected.path, .named = selected.named };
    }

    if (try known.has(candidate)) return .{ .path = candidate, .named = false };

    const indexed = try index(allocator, candidate);

    {
        errdefer allocator.free(indexed);

        if (try known.has(indexed)) return .{ .path = indexed, .named = false };
    }

    allocator.free(indexed);

    const end = candidate.len - ".zx".len - member.len - 1;
    const owner = try std.mem.concat(allocator, u8, &.{ candidate[0..end], ".zx" });

    errdefer allocator.free(owner);

    const path = try select(allocator, owner, known);

    if (path.ptr != owner.ptr) allocator.free(owner);

    return .{ .path = path, .named = true };
}

pub fn directoryReference(path: []const u8) bool {
    const name = std.fs.path.basename(path);

    if (comptime generated) {
        const directory_kind = @import("generated_module_directory");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input: std.meta.Child(directory_kind.Input) = .{ .path = path, .basename = name };

        return zx.columns.invoke(directory_kind.executeValue, empty.allocator(), &input) catch unreachable;
    }

    return std.mem.endsWith(u8, path, "/") or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

pub fn directory(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return directoryFor(allocator, path, false);
}

pub fn directoryFor(allocator: std.mem.Allocator, path: []const u8, rx: bool) std.mem.Allocator.Error![]const u8 {
    return indexFor(allocator, std.mem.trimEnd(u8, path, "/"), rx);
}

fn indexFor(allocator: std.mem.Allocator, path: []const u8, rx: bool) std.mem.Allocator.Error![]const u8 {
    if (comptime generated) {
        const target = @import("generated_module_path");
        const input: std.meta.Child(target.Input) = .{ .directory = path, .rx = rx };

        return zx.columns.invoke(target.executeValue, allocator, &input) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        };
    }

    return std.fs.path.join(allocator, &.{ path, if (rx) "index.rx" else "index.zx" });
}
