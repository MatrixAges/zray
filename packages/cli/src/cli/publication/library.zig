const std = @import("std");
const effects = @import("effects.zig");
const Directory = @import("directory.zig");
const Verification = @import("verification.zig");
const inventory = @import("../library/inventory.zig");
const retirement = @import("../library/retirement/storage.zig");
const output = @import("../watch/output.zig");
const Self = @This();

directory: *Directory,
verification: *Verification,
managed: []const inventory.File,
retired: []const []const u8 = &.{},
files: std.ArrayList(File) = .empty,
manifest: []const u8 = undefined,
const File = struct {
    target: []const u8,
    relative: []const u8,
};

pub fn inputCount(handle: *const anyopaque) u64 {
    return effects.borrow(Self, handle).verification.snapshot.?.entries.len;
}

pub fn relativeInput(handle: *const anyopaque, index: u64) effects.Error![]const u8 {
    const self = effects.borrow(Self, handle);
    const directory = self.directory;
    const entry = self.verification.snapshot.?.entries[@intCast(index)];

    return std.fs.path.relative(directory.allocator, directory.destination, null, directory.destination, entry.path) catch |err| return directory.failure.save(err);
}

pub const absolutePath = std.fs.path.isAbsolute;

pub fn prepareRetirement(handle: *const anyopaque) effects.Error!void {
    const self = effects.borrow(Self, handle);
    const directory = self.directory;
    self.retired = retirement.retired(directory.io, directory.allocator, self.verification.allocator, directory.destination, self.managed, self.verification.inputs) catch |err| return directory.failure.save(err);
}

pub fn validateEntry(handle: *const anyopaque, is_inventory: bool) effects.Error!void {
    const self = effects.borrow(Self, handle);
    const directory = self.directory;
    const path = directory.path;
    const target = std.fs.path.join(directory.allocator, &.{ directory.destination, path }) catch |err| return directory.failure.save(err);
    const physical = output.check(directory.io, directory.allocator, self.verification.inputs, target) catch |err| return directory.failure.save(err);

    directory.allocator.free(physical);

    if (is_inventory) {
        self.manifest = target;
    } else {
        const relative = target[target.len - path.len ..];

        self.files.append(directory.allocator, .{ .target = target, .relative = relative }) catch |err| return directory.failure.save(err);
    }
}

pub fn contentCount(handle: *const anyopaque) u64 {
    return effects.borrow(Self, handle).files.items.len;
}

pub fn copyContent(handle: *const anyopaque, index: u64) effects.Error!void {
    const self = effects.borrow(Self, handle);
    const item = self.files.items[@intCast(index)];

    return self.directory.copy(item.relative, item.target);
}

pub fn retiredCount(handle: *const anyopaque) u64 {
    return effects.borrow(Self, handle).retired.len;
}

pub fn removeRetired(handle: *const anyopaque, index: u64) effects.Error!void {
    const self = effects.borrow(Self, handle);
    const directory = self.directory;

    std.Io.Dir.cwd().deleteFile(directory.io, self.retired[@intCast(index)]) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return directory.failure.save(err),
    };
}

pub fn copyInventory(handle: *const anyopaque) effects.Error!void {
    const self = effects.borrow(Self, handle);

    return self.directory.copy(inventory.name, self.manifest);
}
