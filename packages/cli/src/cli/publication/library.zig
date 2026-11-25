const std = @import("std");
const effects = @import("effects.zig");
const Directory = @import("directory.zig");
const Verification = @import("verification.zig");
const inventory = @import("../library/inventory.zig");
const retirement = @import("../library/retirement/storage.zig");
const output = @import("../watch/output.zig");
const memory = @import("zx").memory;
const Self = @This();

directory: *Directory,
verification: *Verification,
managed: []const inventory.File,
observed: memory.TextColumn = undefined,
pub fn captureLibraryInputs(handle: *const anyopaque) effects.Error!u64 {
    const self = effects.borrow(Self, handle);

    try Verification.capture(self.verification);

    self.observed = memory.borrowTextColumn("path", self.verification.snapshot.?.entries);

    return self.observed.count;
}

pub fn relativeInput(handle: *const anyopaque, path: []const u8) effects.Error![]const u8 {
    const self = effects.borrow(Self, handle);
    const directory = self.directory;

    return std.fs.path.relative(directory.allocator, directory.destination, null, directory.destination, path) catch |err| return directory.failure.save(err);
}

pub const absolutePath = std.fs.path.isAbsolute;

pub fn prepareRetirement(handle: *const anyopaque) effects.Error![]const []const u8 {
    const self = effects.borrow(Self, handle);
    const directory = self.directory;

    return retirement.retired(directory.io, directory.allocator, self.verification.allocator, directory.destination, self.managed, self.verification.inputs) catch |err| return directory.failure.save(err);
}

pub fn validatePublishedPath(handle: *const anyopaque, path: []const u8) effects.Error![]const u8 {
    const self = effects.borrow(Self, handle);
    const directory = self.directory;
    const target = std.fs.path.join(directory.allocator, &.{ directory.destination, path }) catch |err| return directory.failure.save(err);
    const physical = output.check(directory.io, directory.allocator, self.verification.inputs, target) catch |err| return directory.failure.save(err);

    directory.allocator.free(physical);

    return target;
}
