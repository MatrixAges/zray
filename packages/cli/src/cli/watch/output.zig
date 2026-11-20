const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;

pub fn check(io: std.Io, allocator: std.mem.Allocator, inputs: *const Inputs, path: []const u8) ![:0]u8 {
    const absolute = try std.fs.path.resolve(allocator, &.{ inputs.cwd, path });

    defer allocator.free(absolute);

    const parent = try physicalDirectory(io, allocator, std.fs.path.dirname(absolute).?);

    defer allocator.free(parent);

    var target = try std.fs.path.joinZ(allocator, &.{ parent, std.fs.path.basename(absolute) });

    errdefer allocator.free(target);

    const existing = std.Io.Dir.cwd().statFile(io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (existing) |file| {
        if (file.kind != .sym_link) {
            const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, absolute, allocator);

            allocator.free(target);

            target = resolved;
        }
    }

    var cursor: Cursor = .{ .entries = inputs.entries.iterator() };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const overlaps = @import("cli_source").publication_overlap.executeIn(empty.allocator(), &.{
        .paths = @ptrCast(&cursor),
        .logical = absolute,
        .physical = target,
    }) catch unreachable;

    if (overlaps) return error.OutputOverlapsInput;

    return target;
}

fn physicalDirectory(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| {
        if (err != error.FileNotFound) return err;

        const parent = std.fs.path.dirname(path) orelse return err;
        const physical = try physicalDirectory(io, allocator, parent);

        defer allocator.free(physical);

        return std.fs.path.joinZ(allocator, &.{ physical, std.fs.path.basename(path) });
    };
}

const Cursor = struct {
    entries: Inputs.Observations.Iterator,
    current: Inputs.Observations.Entry = undefined,
    fn get(handle: *const anyopaque) *Cursor {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn nextInput(handle: *const anyopaque) bool {
    const self = Cursor.get(handle);

    self.current = self.entries.next() orelse return false;

    return true;
}

pub fn logicalPath(handle: *const anyopaque) []const u8 {
    return Cursor.get(handle).current.key_ptr.*;
}

pub fn physicalPath(handle: *const anyopaque) []const u8 {
    const entry = Cursor.get(handle).current;

    return switch (entry.value_ptr.state) {
        .file => |file| file.physical_path,
        .directory => |directory| directory.physical_path,
        else => entry.key_ptr.*,
    };
}
