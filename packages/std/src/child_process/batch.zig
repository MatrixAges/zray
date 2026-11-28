const std = @import("std");
const api = @import("zxc_abi").native.@"std:child_process";
const Allocator = std.mem.Allocator;
const Io = std.Io;
const scratch = std.heap.smp_allocator;

const Failure = union(enum) {
    spawn_error: []const u8,
    terminated: struct { term: std.process.Child.Term, stderr: []u8 },
};

pub fn spawnBatchSync(allocator: Allocator, io: Io, commands: []const []const []const u8) ![]const ?api.BatchFailure {
    if (commands.len == 0) return &.{};

    const failures = try scratch.alloc(?Failure, commands.len);

    defer scratch.free(failures);
    @memset(failures, null);

    defer for (failures) |outcome| {
        if (outcome) |failure| {
            if (failure == .terminated) scratch.free(failure.terminated.stderr);
        }
    };

    var work: Work = .{ .io = io, .commands = commands, .failures = failures };
    var group: Io.Group = .init;

    defer group.cancel(io);

    const pool_size = @min(commands.len, std.Thread.getCpuCount() catch 1);

    for (1..pool_size) |_| {
        group.concurrent(io, Work.run, .{&work}) catch break;
    }

    work.run();

    try group.await(io);

    const results = try allocator.alloc(?api.BatchFailure, commands.len);
    var written: usize = 0;

    errdefer {
        for (results[0..written]) |result| {
            if (result) |failure| {
                if (failure.termination) |termination| allocator.free(termination);

                allocator.free(failure.stderr);
                allocator.destroy(failure);
            }
        }

        allocator.free(results);
    }

    for (results, failures) |*result, outcome| {
        result.* = if (outcome) |failure| try materialize(allocator, failure) else null;
        written += 1;
    }

    return results;
}

const Work = struct {
    io: Io,
    commands: []const []const []const u8,
    failures: []?Failure,
    next: usize = 0,
    mutex: Io.Mutex = .init,
    fn claim(self: *Work) ?usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.next == self.commands.len) return null;

        const position = self.next;

        self.next += 1;

        return position;
    }
    fn run(self: *Work) void {
        while (self.claim()) |position| {
            self.failures[position] = capture(self.io, self.commands[position]) catch |err|
                .{ .spawn_error = @errorName(err) };
        }
    }
};

fn capture(io: Io, argv: []const []const u8) !?Failure {
    try @import("options.zig").validateArgv(argv);

    const result = try std.process.run(scratch, io, .{ .argv = argv });

    scratch.free(result.stdout);

    if (result.term.success()) {
        scratch.free(result.stderr);

        return null;
    }

    return .{ .terminated = .{ .term = result.term, .stderr = result.stderr } };
}

fn materialize(allocator: Allocator, failure: Failure) !api.BatchFailure {
    const result = try allocator.create(@typeInfo(api.BatchFailure).pointer.child);

    errdefer allocator.destroy(result);

    switch (failure) {
        .spawn_error => |name| result.* = .{
            .spawn_error = name,
            .termination = null,
            .stderr = &.{},
        },
        .terminated => |terminated| {
            const stderr = try allocator.dupe(u8, terminated.stderr);

            errdefer allocator.free(stderr);

            result.* = .{
                .spawn_error = null,
                .termination = try std.fmt.allocPrint(allocator, "{any}", .{terminated.term}),
                .stderr = stderr,
            };
        },
    }

    return result;
}
