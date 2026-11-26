const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const effects = @import("../publication/effects.zig");
const rule = @import("cli_source").check_output_target;
const Error = effects.Error;

const Target = struct {
    io: std.Io,
    failure: effects.Failure = .{},
    physical: [std.Io.Dir.max_path_bytes]u8 = undefined,
};

pub fn check(io: std.Io, allocator: std.mem.Allocator, inputs: *const Inputs, path: []const u8) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    var target: Target = .{ .io = io };

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

    const outcome = rule.executeIn(scratch_allocator, &.{
        .target = @ptrCast(&target),
        .cwd = inputs.cwd,
        .path = path,
        .logical_inputs = logical_inputs,
        .physical_inputs = physical_inputs,
    }) catch |err| return target.failure.unwrap(err);

    return switch (outcome.status) {
        .Ready => allocator.dupeSentinel(u8, outcome.path.?, 0),
        .MissingParent => error.FileNotFound,
        .Overlap => error.OutputOverlapsInput,
    };
}

pub fn readOutputPath(handle: *anyopaque, path: []const u8, allow_missing: bool) Error![]const u8 {
    const self = effects.borrow(Target, handle);

    const length = std.Io.Dir.cwd().realPathFile(self.io, path, &self.physical) catch |err| {
        if (allow_missing and err == error.FileNotFound) return "";

        return self.failure.save(err);
    };

    return self.physical[0..length];
}

pub fn isDirectOutput(handle: *anyopaque, path: []const u8) Error!bool {
    const self = effects.borrow(Target, handle);

    const existing = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.failure.save(err),
    };

    return existing.kind != .sym_link;
}
