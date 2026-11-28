const std = @import("std");
const Snapshot = @import("../snapshot.zig");
const read = @import("read.zig");
const Context = read.Context;
const storage = @import("storage.zig");
const Error = storage.Error;
const rule = @import("cli_source").scan;

pub fn scan(snapshot: Snapshot, io: std.Io, allocator: std.mem.Allocator, versioned: bool, reuse_versions: bool) !bool {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    var workflow = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();
    defer workflow.deinit();

    var context: Context = .{
        .io = io,
        .allocator = scratch.allocator(),
        .started = if (versioned and snapshot.consistent) std.Io.Timestamp.now(io, .real).nanoseconds else 0,
        .scan = .{ .entries = snapshot.entries, .scratch = &scratch },
    };

    const handle = &context;

    return rule.execute(&workflow, &.{
        .scan = @ptrCast(&handle),
        .count = snapshot.entries.len,
        .consistent = snapshot.consistent,
        .versioned = versioned,
        .reuse_versions = reuse_versions,
    }) catch |err| if (err == error.ObservationFailure) context.failure.? else err;
}

pub fn versionMatches(handle: *const anyopaque, index: u64) Error!bool {
    const self = Context.get(handle);

    return self.scan.?.entries[@intCast(index)].stillMatches(self.io) catch |err| self.fail(err);
}

pub fn readRow(handle: *const anyopaque, index: u64, versioned: bool) Error!*const storage.Comparison {
    const self = Context.get(handle);
    const entry = &self.scan.?.entries[@intCast(index)];

    _ = self.scan.?.scratch.reset(.retain_capacity);
    self.path = entry.path;
    self.save_version = versioned;
    self.verified_file = null;

    read.observe(self, entry.directory_entries) catch |err| return self.fail(err);

    self.left = Snapshot.fact(&entry.state);
    self.right = Snapshot.fact(&self.result);
    self.comparison = .{ .left = &self.left, .right = &self.right };

    return &self.comparison;
}

pub fn acceptVersion(handle: *const anyopaque, index: u64) void {
    const self = Context.get(handle);

    self.scan.?.entries[@intCast(index)].verified_file = self.verified_file;
}
