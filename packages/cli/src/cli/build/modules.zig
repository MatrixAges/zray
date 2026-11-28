const std = @import("std");
const compiler = @import("compiler");
const State = @import("../build.zig").State;
const artifacts = @import("../artifacts.zig");
const process = @import("backend_protocol").process;
const Error = @import("../sources/effects.zig").Error;

pub fn spawnNativeTranslation(handle: *const anyopaque, arguments: []const []const u8) Error!?[]const u8 {
    const self = State.get(handle);
    const translation = &self.translation.?;

    translation.pending = process.run(self.context.io, translation.arena.child_allocator, arguments, &self.environment.?, .translation) catch |err| return self.failure.save(err);

    if (!translation.pending.?.succeeded) return null;

    self.translation_hash = std.fmt.bytesToHex(translation.pending.?.digest.?, .lower);

    return &self.translation_hash;
}

pub fn retainNativeTranslation(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const translation = &self.translation.?;

    translation.responses.append(translation.arena.allocator(), translation.pending.?) catch |err| return self.failure.save(err);

    translation.pending = null;
}

pub fn releaseNativeTranslation(handle: *const anyopaque) void {
    const translation = &State.get(handle).translation.?;

    translation.pending.?.deinit();

    translation.pending = null;
}

pub fn writeNativeAdapter(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const allocator = context.allocator;
    const adapter = compiler.zig.host.cAdapter(allocator) catch |err| return self.failure.save(err);

    defer allocator.free(adapter);
    artifacts.retain(context.io, allocator, path, adapter) catch |err| return self.failure.save(err);
}
