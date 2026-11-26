const std = @import("std");
const Self = @This();
const Ring = @import("pool/ring.zig");

/// Background threads that analyze the bodies the calling thread requests while it walks the worklist on its own. A
/// request waits in a bounded ring; when the ring is full the request is dropped, as the calling thread analyzes any
/// body without a result itself.
workers: []Worker,
threads: []std.Thread,
started: usize = 0,
ring: Ring,
job: Job = undefined,
/// What one worker allocates: passes over a body that every later analysis reuses, the scratch of one analysis, and
/// the results that wait for their visit. The first belongs to the calling thread.
pub const Worker = struct {
    lasting: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    kept: std.heap.ArenaAllocator,
};

const Job = struct { context: *anyopaque, run: *const fn (*anyopaque, *Worker, u32) void };

pub fn init(allocator: std.mem.Allocator, concurrent: bool) std.mem.Allocator.Error!Self {
    const cores = if (concurrent) std.math.clamp(std.Thread.getCpuCount() catch 1, 1, Ring.max_threads) else 1;
    const workers = try allocator.alloc(Worker, cores);
    const ring = try Ring.init(allocator);

    for (workers) |*worker| worker.* = .{ .lasting = .init(std.heap.smp_allocator), .scratch = .init(std.heap.smp_allocator), .kept = .init(std.heap.smp_allocator) };

    return .{ .workers = workers, .threads = try allocator.alloc(std.Thread, cores - 1), .ring = ring };
}

pub fn deinit(self: *Self) void {
    self.drain();
    self.ring.stop();

    for (self.threads[0..self.started]) |thread| thread.join();

    for (self.workers) |*worker| {
        worker.lasting.deinit();
        worker.scratch.deinit();
        worker.kept.deinit();
    }
}

/// Background threads, the calling thread aside.
pub fn count(self: *const Self) usize {
    return self.threads.len;
}

/// Runs `run(context, worker, index)` for every later request; only while no request is pending.
pub fn serve(self: *Self, comptime Context: type, comptime run: fn (*Context, *Worker, u32) void, context: *Context) void {
    self.job = .{ .context = context, .run = struct {
        fn erased(erased_context: *anyopaque, worker: *Worker, index: u32) void {
            run(@ptrCast(@alignCast(erased_context)), worker, index);
        }
    }.erased };
}

/// Queues body `index` for a background thread; false when the ring is full.
pub fn submit(self: *Self, index: u32) bool {
    if (self.threads.len == 0) return false;

    const position = self.ring.reserve() orelse return false;

    self.publishReserved(position, index);

    return true;
}

pub fn publishReserved(self: *Self, position: u32, index: u32) void {
    if (self.started < self.threads.len) self.start();

    self.ring.publish(position, index);
}

/// Drops every request no worker took and waits for the workers that hold one.
pub fn drain(self: *Self) void {
    self.ring.drain();
}

/// Frees every result kept so far; only once drained.
pub fn forget(self: *Self) void {
    for (self.workers) |*worker| _ = worker.kept.reset(.retain_capacity);
}

fn start(self: *Self) void {
    while (self.started < self.threads.len) : (self.started += 1) {
        self.threads[self.started] = std.Thread.spawn(.{}, work, .{ self, &self.workers[self.started + 1] }) catch return;
    }
}

fn work(self: *Self, worker: *Worker) void {
    while (self.ring.take()) |index| {
        _ = worker.scratch.reset(.retain_capacity);

        self.job.run(self.job.context, worker, index);
        self.ring.complete();
    }
}
