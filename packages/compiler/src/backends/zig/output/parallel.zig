const std = @import("std");
const generated = @import("parser_options").generated_parser;
const worker = if (generated) @import("generated_bootstrap_output_worker") else void;
const Input = if (generated) std.meta.Child(worker.Input) else void;
pub const Request = if (generated) std.meta.Child(@FieldType(Input, "jobs")) else void;

/// One arena per worker, so steps running at once never share an allocator; the workers are `io`'s pooled threads.
pub const Arenas = struct {
    io: std.Io,
    items: []std.heap.ArenaAllocator,
    /// Workers for `jobs` steps: at most one per core, and at least one.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, jobs: usize) std.mem.Allocator.Error!Arenas {
        const items = try allocator.alloc(std.heap.ArenaAllocator, @max(@min(std.Thread.getCpuCount() catch 1, jobs), 1));

        for (items) |*arena| arena.* = .init(std.heap.smp_allocator);

        return .{ .io = io, .items = items };
    }

    pub fn deinit(self: Arenas) void {
        for (self.items) |*arena| arena.deinit();
    }
};

pub fn each(arenas: Arenas, request: Request) !void {
    var work: Work = .{ .request = request };

    return spread(arenas, &work, Work.run);
}

const Work = struct {
    request: Request,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u32) = .init(0),
    fn run(self: *Work, arena: *std.heap.ArenaAllocator) void {
        const allocator = arena.allocator();
        var failure: []u32 = @as(*[1]u32, @ptrCast(&self.failure.raw));

        const input: Input = .{
            .jobs = &self.request,
            .allocator = @ptrCast(&allocator),
            .cursor = @ptrCast(&self.next),
            .failure = @ptrCast(&failure),
        };

        worker.executeIn(allocator, &input) catch unreachable;
    }
};

pub fn eachSeed(arenas: Arenas, count: usize, context: anytype) !void {
    const Context = @TypeOf(context);

    const Seed = struct {
        context: Context,
        count: usize,
        next: std.atomic.Value(usize) = .init(0),
        failure: std.atomic.Value(u16) = .init(0),
        fn run(work: *@This(), arena: *std.heap.ArenaAllocator) void {
            while (work.failure.load(.monotonic) == 0) {
                const index = work.next.fetchAdd(1, .monotonic);

                if (index >= work.count) return;

                work.context.step(arena.allocator(), index) catch |err| {
                    _ = work.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                    return;
                };
            }
        }
    };

    var work = Seed{ .context = context, .count = count };

    return spread(arenas, &work, Seed.run);
}

fn spread(arenas: Arenas, work: anytype, comptime run: anytype) !void {
    var group: std.Io.Group = .init;

    for (arenas.items[1..]) |*arena| group.async(arenas.io, run, .{ work, arena });

    run(work, &arenas.items[0]);
    group.await(arenas.io) catch {};

    const code = work.failure.load(.monotonic);

    if (code != 0) return @errorCast(@errorFromInt(@as(u16, @intCast(code))));
}
