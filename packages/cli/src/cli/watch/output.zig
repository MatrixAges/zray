const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const rule = @import("cli_source").check_output_target;
const FileKind = @import("publication_abi").native.@"zig:publication_host".PublicationFileKind;

pub fn check(io: std.Io, allocator: std.mem.Allocator, inputs: *const Inputs, path: []const u8) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const scratch_allocator = scratch.allocator();
    const count = inputs.entries.count();
    const logical_inputs = try scratch_allocator.alloc([]const u8, count);
    const physical_inputs = try scratch_allocator.alloc([]const u8, count);
    var entries = inputs.entries.iterator();
    var index: usize = 0;

    while (entries.next()) |entry| : (index += 1) {
        logical_inputs[index] = entry.key_ptr.*;

        physical_inputs[index] = switch (entry.value_ptr.state) {
            .file => |file| file.physical_path,
            .directory => |directory| directory.physical_path,
            else => entry.key_ptr.*,
        };
    }

    const outcome = try rule.executeIn(scratch_allocator, &.{
        .cwd = inputs.cwd,
        .path = path,
        .logical_inputs = logical_inputs,
        .physical_inputs = physical_inputs,
    }, io);

    return switch (outcome.status) {
        .Ready => allocator.dupeSentinel(u8, outcome.path.?, 0),
        .MissingParent => error.FileNotFound,
        .Overlap => error.OutputOverlapsInput,
    };
}

pub fn resolvePublicationPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, allow_missing: bool) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const length = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch |err| {
        if (allow_missing and err == error.FileNotFound) return "";

        return err;
    };

    return allocator.dupe(u8, buffer[0..length]);
}

pub fn readPublicationFileKind(io: std.Io, path: []const u8) !FileKind {
    const metadata = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        inline else => |cause| return cause,
    };

    return switch (metadata.kind) {
        .file => .Regular,
        .sym_link => .Symlink,
        else => .Other,
    };
}
