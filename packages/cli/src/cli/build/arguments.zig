const std = @import("std");
const State = @import("../build.zig").State;
const artifacts = @import("../artifacts.zig");
const Error = @import("../sources/effects.zig").Error;

pub fn writeBackendCommand(handle: *const anyopaque, arguments: []const []const u8) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const manifest = std.json.Stringify.valueAlloc(context.allocator, arguments, .{ .whitespace = .indent_2 }) catch |err| return self.failure.save(err);
    const path = std.fs.path.join(context.allocator, &.{ self.workspace.directory, "command.json" }) catch |err| return self.failure.save(err);

    artifacts.write(context.io, path, manifest) catch |err| return self.failure.save(err);
}
