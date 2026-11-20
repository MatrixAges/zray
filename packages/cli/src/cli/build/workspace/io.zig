const std = @import("std");
const Error = error{ArtifactIoFailure};

pub const Context = struct {
    io: std.Io,
    failure: ?anyerror = null,
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn matches(handle: *const anyopaque, path: []const u8, expected: []const u8) Error!bool {
    const context = Context.get(handle);

    return matchesFile(context.io, path, expected) catch |err| {
        context.failure = err;

        return error.ArtifactIoFailure;
    };
}

pub fn writeAtomic(handle: *const anyopaque, path: []const u8, source: []const u8) Error!void {
    const context = Context.get(handle);

    write(context.io, path, source) catch |err| {
        context.failure = err;

        return error.ArtifactIoFailure;
    };
}

pub fn write(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    try file.file.writeStreamingAll(io, content);
    try file.replace(io);
}

fn matchesFile(io: std.Io, path: []const u8, expected: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = @import("builtin").os.tag != .windows }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    defer file.close(io);

    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var remaining = expected;
    var equal = true;

    while (true) {
        const data = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return equal and remaining.len == 0,
            error.ReadFailed => return reader.err.?,
        };

        if (data.len > remaining.len) return false;

        equal = equal and std.mem.eql(u8, data, remaining[0..data.len]);
        remaining = remaining[data.len..];

        reader.interface.tossBuffered();
    }
}
