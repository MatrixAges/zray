const std = @import("std");
const Inputs = @import("../cli/watch/inputs.zig");
const compiler = @import("compiler");
const zx = @import("zx");
const source = @import("manifest/input.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const rules = @import("cli_source");
const constants = rules.workspace_constants.@"zx.constants";
pub const Package = struct { path: []const u8, manifest: Manifest };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "",
    packages: []const Package = &.{},
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Result {
    return loadPrepared(io, allocator, .{ .path = path });
}

pub const Request = struct {
    path: []const u8,
    inputs: ?*Inputs = null,
    manifests: ?std.mem.Allocator = null,
    root: ?source.Known = null,
    member: ?source.Known = null,
};

pub fn loadPrepared(io: std.Io, allocator: std.mem.Allocator, request: Request) !Result {
    if (request.inputs) |observed| try observed.add(io, request.path);

    var result: Result = .{ .arena = .init(allocator) };

    errdefer result.deinit();

    result.packages = collect(io, &result, request, request.manifests orelse result.arena.allocator()) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}: {s}", .{ request.path, @errorName(err) });

        return result;
    };

    return result;
}

fn collect(io: std.Io, result: *Result, request: Request, manifests: std.mem.Allocator) ![]const Package {
    const allocator = result.arena.allocator();
    const path = request.path;
    const inputs = request.inputs;
    const root_path = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse constants.root_path, allocator);
    result.root = root_path;

    const root = try read(io, result, path, inputs, manifests, request.root);
    var packages: std.ArrayList(Package) = .empty;

    try packages.append(allocator, .{ .path = constants.root_path, .manifest = root });

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

    var names: compiler.project.source_index.Owned = .{};
    var registry = std.heap.ArenaAllocator.init(result.arena.child_allocator);

    defer registry.deinit();

    _ = try names.register(registry.allocator(), root.name, 0);

    for (paths.items, 1..) |member, index| {
        const member_path = try std.fs.path.join(allocator, &.{ root_path, member, "pkg.yaml" });

        const data = read(io, result, member_path, inputs, manifests, request.member) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                if (err == error.OutOfMemory) return err;
                if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ member_path, @errorName(err) });

                return err;
            },
        };

        if (try names.register(registry.allocator(), data.name, index)) |previous| {
            const first = if (previous == 0) constants.root_path else paths.items[previous - 1];

            result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: duplicate workspace package {s}; first declared at {s}", .{ member_path, data.name, first });

            return error.InvalidWorkspace;
        }

        const portable = try portablePath(allocator, member);

        try packages.append(allocator, .{ .path = portable, .manifest = data });
    }

    return try packages.toOwnedSlice(allocator);
}

fn read(io: std.Io, result: *Result, path: []const u8, inputs: ?*Inputs, manifests: std.mem.Allocator, known: ?source.Known) !Manifest {
    const allocator = result.arena.allocator();
    const file = try source.locate(io, allocator, path, inputs);
    const relative = try std.fs.path.relative(allocator, result.root, null, result.root, file.physical);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const within = rules.workspace_manifest_within.executeValue(scratch.allocator(), &.{
        .path = relative,
        .absolute = std.fs.path.isAbsolute(relative),
    }) catch unreachable;

    if (!within) {
        result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: manifest escapes the workspace root", .{path});

        return error.InvalidWorkspace;
    }

    if (known) |prepared| {
        if (prepared.matches(file)) return prepared.data;
    }

    return switch (try source.decode(io, manifests, file, inputs)) {
        .data => |data| data,
        .diagnostic => |issue| {
            result.diagnostic = try source.diagnostic(allocator, path, issue);

            return error.InvalidWorkspace;
        },
    };
}

pub fn portablePath(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return rules.workspace_portable_path.executeValue(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

pub fn containsMember(members: []const Package, path: []const u8) bool {
    const paths = zx.memory.borrowTextColumn("path", members);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return rules.workspace_member_path.executeValue(scratch.allocator(), &.{
        .paths = @ptrCast(&paths),
        .count = members.len,
        .target = path,
    }) catch unreachable;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
