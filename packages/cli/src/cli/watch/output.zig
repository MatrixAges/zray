const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const effects = @import("../publication/effects.zig");
const rule = @import("cli_source").check_output_target;
const Error = effects.Error;

const Target = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: *const Inputs,
    entries: Inputs.Observations.Iterator,
    failure: effects.Failure = .{},
    physical: [std.Io.Dir.max_path_bytes]u8 = undefined,
    result: ?[:0]u8 = null,
};

pub fn check(io: std.Io, allocator: std.mem.Allocator, inputs: *const Inputs, path: []const u8) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    var target: Target = .{ .io = io, .allocator = allocator, .inputs = inputs, .entries = inputs.entries.iterator() };

    defer arena.deinit();
    errdefer if (target.result) |result| allocator.free(result);

    const status = rule.executeIn(scratch.allocator(), &.{
        .target = @ptrCast(&target),
        .cwd = inputs.cwd,
        .path = path,
    }) catch |err| return target.failure.unwrap(err);

    return switch (status) {
        .Ready => target.result.?,
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

pub fn keepOutputPath(handle: *anyopaque, base: []const u8, logical: []const u8, prefix: u64) Error![]const u8 {
    const self = effects.borrow(Target, handle);
    const result = std.fs.path.joinZ(self.allocator, &.{ base, logical[@intCast(prefix)..] }) catch |err| return self.failure.save(err);
    self.result = result;

    return result;
}

pub fn observedLogicalOutput(handle: *anyopaque, path: []const u8) bool {
    return effects.borrow(Target, handle).inputs.entries.contains(path);
}

pub fn nextPhysicalInput(handle: *anyopaque) ?[]const u8 {
    const entry = effects.borrow(Target, handle).entries.next() orelse return null;

    return switch (entry.value_ptr.state) {
        .file => |file| file.physical_path,
        .directory => |directory| directory.physical_path,
        else => entry.key_ptr.*,
    };
}
