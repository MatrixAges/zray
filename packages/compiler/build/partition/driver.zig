const std = @import("std");
const rules = @import("partition_rules");
const native = @import("partition_abi").layouts.@"zig:partition_host";
const cache_key = @import("cache_key.zig");
const state = @import("state.zig");
const workers = @import("workers.zig");
const Listed = @import("file_manifest").Listed;
const Request = @typeInfo(result(rules.partition_request_parse)).optional.child;
const Selection = result(rules.partition_cache_selection);
const Failure = error{PartitionHost};
const Self = @This();

fn result(comptime entry: type) type {
    return @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload;
}

io: std.Io,
allocator: std.mem.Allocator,
workspace: std.mem.Allocator,
request: Request,
listed: Listed,
selected: Selection,
shared: cache_key.Shared = .{},

keys: cache_key.Partitions = undefined,
state_path: []const u8 = undefined,
previous: []const u8 = undefined,
present: []bool = &.{},
schedule: state.Schedule = undefined,
diagnostics: []const ?[]const u8 = &.{},
objects: native.PartitionObjects = undefined,
scheduled: native.PartitionSchedule = undefined,
completed: native.PartitionResults = undefined,

failure: ?anyerror = null,

pub fn execute(self: *Self) !bool {
    const entry = rules.partition_objects;

    const input: std.meta.Child(entry.Input) = .{
        .target = @ptrCast(self),
        .external = self.request.inputs,
        .offsets = self.selected.offsets,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input) catch |err| return self.failure orelse err;
}

fn borrow(handle: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(handle)));
}

fn fail(self: *Self, err: anyerror) Failure {
    self.failure = err;

    return error.PartitionHost;
}

pub fn startPartitionHash(handle: *const anyopaque) Failure!void {
    const self = borrow(handle);
    const stat = std.Io.Dir.cwd().statFile(self.io, self.request.zig, .{}) catch |err| return self.fail(err);
    const selected = self.selected;

    self.shared.init();

    self.shared.prefix(
        self.request.zig,
        stat,
        self.request.arguments,
        selected.types orelse return self.fail(error.MissingGeneratedFile),
        selected.signatures orelse return self.fail(error.MissingGeneratedFile),
    );
}

pub fn hashExternalInput(handle: *const anyopaque, path: []const u8) Failure!void {
    const self = borrow(handle);

    self.shared.input(self.io, self.workspace, path) catch |err| return self.fail(err);
}

pub fn allocatePartitionKeys(handle: *const anyopaque, count: u64) Failure!void {
    const self = borrow(handle);

    self.keys = cache_key.Partitions.init(self.allocator, self.shared.state(), @intCast(count)) catch |err| return self.fail(err);
}

pub fn hashPartitionMembers(handle: *const anyopaque, row: u64, first: u64, end: u64) void {
    const self = borrow(handle);

    self.keys.hash(@intCast(row), self.listed, self.selected.members[@intCast(first)..@intCast(end)]);
}

pub fn loadPartitionObjects(handle: *const anyopaque, state_file: []const u8) Failure!*const native.PartitionObjects {
    const self = borrow(handle);

    self.load(state_file) catch |err| return self.fail(err);

    return &self.objects;
}

fn load(self: *Self, state_file: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const output = self.request.objects;
    const allocator = self.allocator;

    self.state_path = try std.fs.path.join(allocator, &.{ output, state_file });

    self.previous = cwd.readFileAlloc(self.io, self.state_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    try cwd.createDirPath(self.io, output);

    const paths = try rules.partition_object_paths.executeValue(allocator, &.{ .objects = output, .count = self.keys.hex.len });
    self.present = try allocator.alloc(bool, paths.len);
    self.objects = .{ .target = @ptrCast(self), .paths = paths };
}

pub fn recordPartitionPresence(handle: *const anyopaque, row: u64, path: []const u8) void {
    const self = borrow(handle);

    self.present[@intCast(row)] = if (std.Io.Dir.cwd().access(self.io, path, .{})) true else |_| false;
}

pub fn schedulePartitionObjects(handle: *const anyopaque) Failure!*const native.PartitionSchedule {
    const self = borrow(handle);
    const keys: state.Keys = .{ .hex = self.keys.hex };

    self.schedule = keys.plan(self.allocator, self.previous, self.present, &.{
        .arguments = self.request.arguments,
        .generated = self.request.generated,
        .objects = self.request.objects,
    }) catch |err| return self.fail(err);

    self.scheduled = .{ .target = @ptrCast(self), .pending = self.schedule.pending, .invalidate = self.schedule.invalidate };

    return &self.scheduled;
}

pub fn publishPartitionState(handle: *const anyopaque) Failure!void {
    const self = borrow(handle);
    const keys: state.Keys = .{ .hex = self.keys.hex };

    keys.write(self.io, self.allocator, self.state_path, self.present) catch |err| return self.fail(err);
}

pub fn compilePartitionObjects(handle: *const anyopaque) Failure!void {
    const self = borrow(handle);

    self.diagnostics = workers.compile(self.io, self.allocator, self.request.zig, self.schedule) catch |err| return self.fail(err);
}

pub fn completePartitionObjects(handle: *const anyopaque) Failure!*const native.PartitionResults {
    const self = borrow(handle);
    const failed = state.complete(self.schedule.pending, self.diagnostics, self.present) catch |err| return self.fail(err);

    self.completed = .{ .target = @ptrCast(self), .diagnostics = self.diagnostics, .failed = failed };

    return &self.completed;
}

pub fn reportPartitionDiagnostic(handle: *const anyopaque, diagnostic: []const u8) Failure!void {
    const self = borrow(handle);

    std.Io.File.stderr().writeStreamingAll(self.io, diagnostic) catch |err| return self.fail(err);
}
