const std = @import("std");
const host = @import("../host.zig");
const model = @import("../model.zig");

pub fn verifyLockedManifest(handle: *const anyopaque, row: u64, path: []const u8) host.Error!void {
    const self = host.Context.get(handle);
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer scratch.deinit();

    const memory = scratch.allocator();
    const data = model.read(self.io, memory, path, null, memory) catch |err| return self.fail(err);

    if (!model.matches(data, self.lock.?.lock.packages[@intCast(row)])) return self.fail(error.InstalledManifestDoesNotMatchLock);
}
