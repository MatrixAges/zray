const std = @import("std");
const Inputs = @import("../cli/watch/inputs.zig");
const manifest = @import("manifest.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const rules = @import("cli_source");
pub const Package = struct { path: []const u8, manifest: Manifest };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    packages: []const Package = &.{},
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Result {
    return loadWithInputs(io, allocator, path, null);
}

pub fn loadWithInputs(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inputs: ?*Inputs) !Result {
    return loadRetaining(io, allocator, path, inputs, null);
}

pub fn loadRetaining(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inputs: ?*Inputs, manifests: ?std.mem.Allocator) !Result {
    if (inputs) |observed| try observed.add(io, path);

    var result: Result = .{ .arena = .init(allocator) };

    errdefer result.deinit();

    result.packages = collect(io, &result, path, inputs, manifests orelse result.arena.allocator()) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}: {s}", .{ path, @errorName(err) });

        return result;
    };

    return result;
}

fn collect(io: std.Io, result: *Result, path: []const u8, inputs: ?*Inputs, manifests: std.mem.Allocator) ![]const Package {
    const allocator = result.arena.allocator();
    const root_path = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", allocator);
    const root = try read(io, result, root_path, path, inputs, manifests);
    var packages: std.ArrayList(Package) = .empty;

    try packages.append(allocator, .{ .path = ".", .manifest = root });

    const workspace = root.workspace orelse return try packages.toOwnedSlice(allocator);

    if (workspace.packages.len == 0) return try packages.toOwnedSlice(allocator);

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const patterns = workspace.packages;
    const invalid = rules.workspace_invalid_pattern.executeValue(empty.allocator(), patterns) catch unreachable;

    if (invalid) |index| {
        result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: unsupported workspace pattern: {s}", .{ path, patterns[@intCast(index)] });

        return error.InvalidWorkspace;
    }

    if (inputs) |observed| try observed.add(io, root_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });

    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);

    defer {
        while (walker.stack.items.len > 0) walker.leave(io);

        walker.deinit();
    }

    var paths: std.ArrayList([]const u8) = .empty;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const decision = rules.workspace_directory.executeValue(empty.allocator(), &.{ .patterns = patterns, .path = entry.path, .name = entry.basename }) catch unreachable;

        if (decision.included) try paths.append(allocator, try allocator.dupe(u8, entry.path));
        if (!decision.descendants) continue;

        if (inputs) |observed| {
            const child = try std.fs.path.join(allocator, &.{ root_path, entry.path });

            try observed.add(io, child);
        }

        try walker.enter(io, entry);
    }

    std.mem.sort([]const u8, paths.items, {}, lessThan);

    var names: std.StringHashMap([]const u8) = .init(allocator);

    try names.put(root.name, ".");

    for (paths.items) |member| {
        const member_path = try std.fs.path.join(allocator, &.{ root_path, member, "pkg.yaml" });

        const data = read(io, result, root_path, member_path, inputs, manifests) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                if (err == error.OutOfMemory) return err;
                if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ member_path, @errorName(err) });

                return err;
            },
        };

        const previous = try names.getOrPut(data.name);

        if (previous.found_existing) {
            result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: duplicate workspace package {s}; first declared at {s}", .{ member_path, data.name, previous.value_ptr.* });

            return error.InvalidWorkspace;
        }

        previous.value_ptr.* = member;

        const portable = try allocator.dupe(u8, member);

        std.mem.replaceScalar(u8, portable, '\\', '/');

        try packages.append(allocator, .{ .path = portable, .manifest = data });
    }

    return try packages.toOwnedSlice(allocator);
}

fn read(io: std.Io, result: *Result, root: []const u8, path: []const u8, inputs: ?*Inputs, manifests: std.mem.Allocator) !Manifest {
    const allocator = result.arena.allocator();

    if (inputs) |observed| try observed.add(io, path);

    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    const relative = try std.fs.path.relative(allocator, root, null, root, real);

    if (std.fs.path.isAbsolute(relative) or std.mem.eql(u8, relative, "..") or std.mem.startsWith(u8, relative, "../") or std.mem.startsWith(u8, relative, "..\\")) {
        result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: manifest escapes the workspace root", .{path});

        return error.InvalidWorkspace;
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(io, real, std.heap.smp_allocator, .limited(4 * 1024 * 1024));

    defer std.heap.smp_allocator.free(source);

    if (inputs) |observed| try observed.record(io, path, source);

    const parsed = try manifest.parseInto(manifests, source);

    return switch (parsed) {
        .data => |data| data,
        .diagnostic => |issue| {
            result.diagnostic = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: manifest: {s}", .{ path, issue.line, issue.column, issue.message });

            return error.InvalidWorkspace;
        },
    };
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
