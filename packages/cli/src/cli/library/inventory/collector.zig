const std = @import("std");
const Directory = @import("../../publication/directory.zig");
const effects = @import("../../publication/effects.zig");
const inventory = @import("../inventory.zig");
const rule = @import("cli_source").library_inventory_collect;
const Error = effects.Error;

const Collector = struct {
    directory: *Directory,
    files: std.ArrayList(inventory.File) = .empty,
};

pub fn collect(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const inventory.File {
    var failure: effects.Failure = .{};
    var directory: Directory = .{ .io = io, .allocator = allocator, .failure = &failure, .source = path };
    var collector: Collector = .{ .directory = &directory };

    defer directory.deinit();
    errdefer collector.files.deinit(allocator);

    const state = &collector;
    const valid = rule.executeIn(allocator, @ptrCast(&state)) catch |err| return failure.unwrap(err);

    if (!valid) return error.InvalidLibraryInventory;

    std.mem.sort(inventory.File, collector.files.items, {}, lessThan);

    return collector.files.toOwnedSlice(allocator);
}

pub fn openInventory(handle: *const anyopaque) Error!void {
    return effects.state(Collector, handle).directory.open(true);
}

pub fn nextInventory(handle: *const anyopaque) Error!u8 {
    return effects.state(Collector, handle).directory.nextNamed(inventory.name);
}

pub fn inventoryPath(handle: *const anyopaque) Error![]const u8 {
    const directory = effects.state(Collector, handle).directory;
    const path = directory.allocator.dupe(u8, directory.path) catch |err| return directory.failure.save(err);

    inventory.makePortable(path);

    return path;
}

pub fn addInventoryFile(handle: *const anyopaque, path: []const u8) Error!void {
    const self = effects.state(Collector, handle);
    const directory = self.directory;
    const allocator = directory.allocator;
    const hash = inventory.digest(directory.io, directory.directory, directory.path) catch |err| return directory.failure.save(err);
    const hex = std.fmt.bytesToHex(hash, .lower);
    const digest = allocator.dupe(u8, &hex) catch |err| return directory.failure.save(err);

    self.files.append(allocator, .{ .path = path, .sha256 = digest }) catch |err| return directory.failure.save(err);
}

fn lessThan(_: void, left: inventory.File, right: inventory.File) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}
