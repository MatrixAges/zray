const std = @import("std");
const compiler = @import("compiler");
const State = @import("../build.zig").State;
const artifacts = @import("../artifacts.zig");
const process = @import("backend_protocol").process;
const Error = @import("../sources/effects.zig").Error;

pub fn spawnNativeTranslation(
    allocator: std.mem.Allocator,
    handle: *const anyopaque,
    arguments: []const []const u8,
    observed: bool,
) (Error || std.mem.Allocator.Error)!?[]const u8 {
    const self = State.get(handle);
    const translation = &self.translation.?;
    var result = process.run(self.context.io, translation.arena.child_allocator, arguments, &self.environment.?, .translation) catch |err| return self.failure.save(err);
    var transferred = false;

    defer if (!transferred) result.deinit();

    if (!result.succeeded) {
        translation.pending = result;
        transferred = true;

        return null;
    }

    const digest = try allocator.dupe(u8, &result.digest.?);

    if (observed) {
        try translation.responses.append(translation.arena.allocator(), result);

        transferred = true;
    }

    return digest;
}

pub fn writeNativeAdapter(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const allocator = context.allocator;
    const adapter = compiler.zig.host.cAdapter(allocator) catch |err| return self.failure.save(err);

    defer allocator.free(adapter);
    artifacts.retain(context.io, allocator, path, adapter) catch |err| return self.failure.save(err);
}
