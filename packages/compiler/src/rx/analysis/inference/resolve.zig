const std = @import("std");

pub const Workspace = struct {
    local_frames: [16]u64 = undefined,
    local_values: [32]u32 = undefined,
    extra_frames: std.ArrayList(u64) = .empty,
    extra_values: std.ArrayList(u32) = .empty,
    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.extra_frames.deinit(allocator);
        self.extra_values.deinit(allocator);
    }
};
