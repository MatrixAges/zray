const std = @import("std");
const Entry = @import("cli_abi").layouts.@"zig:package_extract_host".Entry;

pub fn nextTar(allocator: std.mem.Allocator, source: []const u8, offset: u64) !?*const Entry {
    var input: std.Io.Reader = .fixed(source[@intCast(offset)..]);
    var names: [std.fs.max_path_bytes]u8 = undefined;
    var links: [std.fs.max_path_bytes]u8 = undefined;
    var iterator = std.tar.Iterator.init(&input, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    const entry = (try iterator.next()) orelse return null;
    const first = input.seek;
    const end = first + @as(usize, @intCast(entry.size));
    const view = try allocator.create(Entry);

    view.* = .{
        .name = try allocator.dupe(u8, entry.name),
        .kind = switch (entry.kind) {
            .directory => .Directory,
            .file => .File,
            else => .Other,
        },
        .executable = entry.mode & 0o100 != 0,
        .content = input.buffer[first..end],
        .end = offset + end,
    };

    return view;
}

pub fn makeTarDirectory(io: std.Io, handle: *const anyopaque, path: []const u8) std.Io.Dir.CreateDirPathError!void {
    const directory: *const std.Io.Dir = @ptrCast(@alignCast(handle));

    return directory.createDirPath(io, path);
}

const WriteError = std.Io.Dir.CreateDirPathError || std.Io.File.OpenError || std.Io.File.Writer.Error;

pub fn writeTarFile(io: std.Io, handle: *const anyopaque, path: []const u8, content: []const u8, executable: bool) WriteError!void {
    const directory: *const std.Io.Dir = @ptrCast(@alignCast(handle));

    if (std.fs.path.dirname(path)) |parent| try directory.createDirPath(io, parent);

    const file = try directory.createFile(io, path, .{
        .exclusive = true,
        .permissions = if (executable) .executable_file else .default_file,
    });

    defer file.close(io);

    try file.writeStreamingAll(io, content);
}
