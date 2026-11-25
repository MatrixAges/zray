const std = @import("std");
const Error = error{ArtifactIoFailure};

pub fn quoteJsonString(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub const Context = struct {
    io: std.Io,
    directory: std.Io.Dir = .cwd(),
    failure: ?anyerror = null,
    pub fn create(self: Context, path: []const u8) !std.Io.File.Atomic {
        return self.directory.createFileAtomic(self.io, path, .{ .make_path = true, .replace = true });
    }
    pub fn unwrap(self: Context, err: anyerror) anyerror {
        return if (err == error.ArtifactIoFailure) self.failure.? else err;
    }
    pub fn writeFile(self: Context, path: []const u8, content: []const u8) !void {
        var file = try self.create(path);

        defer file.deinit(self.io);

        try file.file.writeStreamingAll(self.io, content);
        try file.replace(self.io);
    }
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn matches(handle: *const anyopaque, path: []const u8, expected: []const u8) Error!bool {
    return (try compare(handle, path, expected, false)) orelse false;
}

pub fn matchesPrefix(handle: *const anyopaque, path: []const u8, prefix: []const u8) Error!?bool {
    return compare(handle, path, prefix, true);
}

fn compare(handle: *const anyopaque, path: []const u8, expected: []const u8, comptime prefix_only: bool) Error!?bool {
    const context = Context.get(handle);

    return matchesFile(context.directory, context.io, path, expected, prefix_only) catch |err| {
        context.failure = err;

        return error.ArtifactIoFailure;
    };
}

pub fn writeAtomic(handle: *const anyopaque, path: []const u8, source: []const u8) Error!void {
    const context = Context.get(handle);

    context.writeFile(path, source) catch |err| {
        context.failure = err;

        return error.ArtifactIoFailure;
    };
}

pub fn write(io: std.Io, path: []const u8, content: []const u8) !void {
    const context: Context = .{ .io = io };

    return context.writeFile(path, content);
}

pub fn digestFile(io: std.Io, file: std.Io.File) std.Io.File.Reader.Error![32]u8 {
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});

    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return hash.finalResult(),
            error.ReadFailed => return reader.err.?,
        };

        hash.update(chunk);
        reader.interface.tossBuffered();
    }
}

fn matchesFile(directory: std.Io.Dir, io: std.Io, path: []const u8, expected: []const u8, comptime prefix_only: bool) !?bool {
    const file = directory.openFile(io, path, .{ .allow_directory = @import("builtin").os.tag != .windows }) catch |err| switch (err) {
        error.FileNotFound => return null,
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

        if (!prefix_only and data.len > remaining.len) return false;

        const width = if (prefix_only) @min(data.len, remaining.len) else data.len;

        equal = equal and std.mem.eql(u8, data[0..width], remaining[0..width]);
        remaining = remaining[width..];

        reader.interface.tossBuffered();
    }
}
