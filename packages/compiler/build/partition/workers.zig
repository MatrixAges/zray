const std = @import("std");
const rules = @import("partition_rules");
const Schedule = @import("state.zig").Schedule;

pub fn compile(io: std.Io, allocator: std.mem.Allocator, zig: []const u8, schedule: Schedule) ![]const ?[]const u8 {
    const pending = schedule.pending;
    const results = try allocator.alloc(?[]const u8, pending.len);

    var work: Work = .{
        .io = io,
        .owner = allocator,
        .zig = zig,
        .arguments = schedule.arguments.values,
        .indexed = schedule.arguments.indexed,
        .pending = pending,
        .results = results,
    };

    const threads = try allocator.alloc(std.Thread, @min(std.Thread.getCpuCount() catch 1, pending.len) -| 1);
    var started: usize = 0;

    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, Work.run, .{&work}) catch break;
        started += 1;
    }

    work.run();

    for (threads[0..started]) |thread| thread.join();

    return results;
}

/// Compiles the pending partitions; a result holds the compiler's output when it failed.
const Work = struct {
    io: std.Io,
    owner: std.mem.Allocator,
    zig: []const u8,
    arguments: []const []const u8,
    indexed: []const u32,
    pending: []const u32,
    results: []?[]const u8,
    next: std.atomic.Value(usize) = .init(0),
    fn run(self: *Work) void {
        while (true) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.pending.len) return;

            self.results[position] = self.compile(self.pending[position]) catch |err| @errorName(err);
        }
    }
    fn compile(self: *Work, index: u32) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

        defer arena.deinit();

        const allocator = arena.allocator();
        const argv = try allocator.alloc([]const u8, self.arguments.len + 1);
        const target = argv[1..];

        argv[0] = self.zig;

        @memcpy(target, self.arguments);

        if (self.indexed.len != 0) try rules.partition_arguments_render.executeValue(allocator, &.{
            .values = self.arguments,
            .indexed = self.indexed,
            .index = index,
            .target = @ptrCast(&target),
        });

        const result = try std.process.run(allocator, self.io, .{ .argv = argv });

        if (result.term == .exited and result.term.exited == 0) return null;

        return try std.fmt.allocPrint(self.owner, "partition {d}: Zig terminated with {any}\n{s}", .{ index, result.term, result.stderr });
    }
};
