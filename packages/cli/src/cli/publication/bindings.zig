const std = @import("std");
const Self = @This();
const disk = @import("artifact_io");
const write = disk.write;
const source = @import("cli_source");
pub const marker = source.publication_constants.@"zx.constants".binding_marker;

module_path: []const u8,
declaration_path: []const u8,
module_source: []const u8,
declarations: []const u8,
pub fn check(self: Self, io: std.Io, allocator: std.mem.Allocator, assembly: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    var filesystem: disk.Context = .{ .io = io };

    defer arena.deinit();

    const status = source.check_binding_targets.executeIn(scratch.allocator(), &.{
        .fs = @ptrCast(&filesystem),
        .module = self.module_path,
        .declaration = self.declaration_path,
        .assembly = assembly,
    }) catch |err| return filesystem.unwrap(err);

    return switch (status) {
        .Ready => {},
        .ConflictingPaths => error.ConflictingOutputPaths,
        .ForeignFile => error.NodeBindingWouldOverwriteFile,
    };
}

pub fn stage(self: Self, io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !void {
    try write(io, try std.fs.path.join(allocator, &.{ directory, std.fs.path.basename(self.module_path) }), self.module_source);
    try write(io, try std.fs.path.join(allocator, &.{ directory, std.fs.path.basename(self.declaration_path) }), self.declarations);
}

pub fn publish(self: Self, io: std.Io) !void {
    try write(io, self.module_path, self.module_source);
    try write(io, self.declaration_path, self.declarations);
}
