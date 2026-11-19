const std = @import("std");
const Inputs = @import("watch/inputs.zig");
const inventory = @import("library/inventory.zig");
const path_rules = @import("native_sources/path.zig");
const rules = @import("cli_source");
const columns = @import("zx").columns;

pub fn retired(io: std.Io, allocator: std.mem.Allocator, backing: std.mem.Allocator, directory: []const u8, current: []const inventory.File, inputs: *Inputs) ![]const []const u8 {
    var previous = try inventory.read(io, backing, directory) orelse return &.{};

    defer previous.deinit();

    var planning = std.heap.ArenaAllocator.init(backing);

    defer planning.deinit();

    const memory = planning.allocator();
    const root = try std.fs.path.resolve(memory, &.{directory});
    const physical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, memory);
    const targets = try Targets.init(memory, root, current);
    var retired_paths: std.ArrayList([]const u8) = .empty;
    var row = std.heap.ArenaAllocator.init(backing);

    defer row.deinit();

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workspace = row.allocator();
    const owned = previous.value.managed_files;
    const files = owned orelse previous.value.bundled_files;

    for (files) |resource| {
        defer _ = row.reset(.retain_capacity);
        const path = try std.fs.path.resolve(workspace, &.{ root, resource.path });
        const relative = try std.fs.path.relative(workspace, root, null, root, path);

        inventory.makePortable(relative);

        const selection = columns.invoke(rules.library_retirement_select.executeValue, empty.allocator(), &.{
            .path = @as([]const u8, relative),
            .absolute = std.fs.path.isAbsolute(relative),
            .native_only = owned == null,
            .retained = targets.names.contains(path),
        }) catch unreachable;

        switch (selection) {
            .Retain => continue,
            .Invalid => return error.InvalidLibraryInventory,
            .Inspect => {},
        }

        const file_kind = try kind(io, path);

        switch (rules.library_retirement_inspect.executeValue(empty.allocator(), file_kind) catch unreachable) {
            .Skip => continue,
            .Modified => return error.LibraryResourceModified,
            .Resolve => {},
        }

        const physical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, workspace);
        const physical_relative = try std.fs.path.relative(workspace, physical_root, null, physical_root, physical);

        if (!path_rules.within(physical_relative)) return error.LibraryResourceOutsideOutput;
        if (try targets.includesPhysical(io, physical)) continue;

        _ = try @import("watch/output.zig").check(io, workspace, inputs, path);

        const hash = try inventory.digest(io, .cwd(), path);
        const hex = std.fmt.bytesToHex(hash, .lower);

        const confirmed = columns.invoke(rules.library_retirement_verify.executeValue, empty.allocator(), &.{
            .actual = @as([]const u8, &hex),
            .expected = resource.sha256,
        }) catch unreachable;

        if (!confirmed) return error.LibraryResourceModified;

        try retired_paths.append(allocator, try allocator.dupe(u8, path));
    }

    return retired_paths.items;
}

fn kind(io: std.Io, path: []const u8) !rules.library_retirement_inspect.Input {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        else => return err,
    };

    return if (stat.kind == .file) .Regular else .Other;
}

const Targets = struct {
    paths: []const []const u8,
    names: std.StringHashMapUnmanaged(void),
    fn init(allocator: std.mem.Allocator, root: []const u8, current: []const inventory.File) !Targets {
        const paths = try allocator.alloc([]const u8, current.len);
        var names: std.StringHashMapUnmanaged(void) = .empty;

        try names.ensureTotalCapacity(allocator, @intCast(current.len));

        for (paths, current) |*path, file| {
            path.* = try std.fs.path.resolve(allocator, &.{ root, file.path });

            names.putAssumeCapacity(path.*, {});
        }

        return .{ .paths = paths, .names = names };
    }
    fn includesPhysical(self: Targets, io: std.Io, physical: []const u8) !bool {
        var retained = false;
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

        for (self.paths) |target| {
            if (try kind(io, target) != .Regular) continue;

            const length = try std.Io.Dir.cwd().realPathFile(io, target, &buffer);

            if (std.mem.eql(u8, physical, buffer[0..length])) retained = true;
        }

        return retained;
    }
};

pub fn remove(io: std.Io, paths: []const []const u8) !void {
    for (paths) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}
