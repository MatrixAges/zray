const std = @import("std");
const native = @import("partition_abi").native.@"zig:partition_host";
const Io = std.Io;

pub fn loadPartitionState(allocator: std.mem.Allocator, io: Io, objects: []const u8, state_file: []const u8) !native.loadPartitionState.Output {
    const cwd = Io.Dir.cwd();
    const path = try std.fs.path.join(allocator, &.{ objects, state_file });

    const previous = cwd.readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    try cwd.createDirPath(io, objects);

    const result = try allocator.create(native.loadPartitionState.OutputValue);

    result.* = .{ .path = path, .previous = previous };

    return result;
}

pub fn partitionObjectPresent(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}
