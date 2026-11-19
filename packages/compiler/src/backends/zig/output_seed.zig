const std = @import("std");
const zx = @import("zx");
const model = @import("output.zig");

pub fn changes(allocator: std.mem.Allocator, input: model.Input) std.mem.Allocator.Error!model.Selection {
    var aligned = input.present and input.paths.len == input.previous_paths.len;
    var by_path: ?zx.bytes.Map(u64) = null;
    var selected: std.ArrayList(u32) = try .initCapacity(allocator, input.paths.len);

    for (input.paths, input.hashes, 0..) |path, hash, position| {
        if (input.present) {
            const before = if (position < input.previous_paths.len and zx.bytes.equal(input.previous_paths[position], path)) input.previous_hashes[position] else found: {
                aligned = false;

                if (by_path == null) {
                    var index: zx.bytes.Map(u64) = .empty;

                    try index.ensureTotalCapacity(allocator, @intCast(input.previous_paths.len));
                    for (input.previous_paths, input.previous_hashes) |name, value| index.putAssumeCapacity(name, value);

                    by_path = index;
                }

                break :found by_path.?.get(path);
            };

            if (before == hash) continue;
        }

        selected.appendAssumeCapacity(@intCast(position));
    }

    return .{ .changed = selected.items, .aligned = aligned };
}

pub fn wanted(allocator: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!model.Index {
    var index: model.Index = .empty;

    try index.ensureTotalCapacity(allocator, @intCast(paths.len));
    for (paths) |path| index.putAssumeCapacity(path, {});

    return index;
}

pub fn parents(allocator: std.mem.Allocator, paths: []const []const u8, changed: []const u32) std.mem.Allocator.Error![]const []const u8 {
    var index: zx.bytes.Map(void) = .empty;
    var result: std.ArrayList([]const u8) = .empty;

    defer index.deinit(allocator);

    for (changed) |row| {
        const parent = std.fs.path.dirname(paths[row]) orelse continue;

        if (!(try index.getOrPut(allocator, parent)).found_existing) try result.append(allocator, parent);
    }

    return result.items;
}
