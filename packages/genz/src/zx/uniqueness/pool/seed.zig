const std = @import("std");
const Self = @This();
pub const max_threads = 8;
const capacity = 256;
const spins = 2000;

ring: []std.atomic.Value(u32),
tail: std.atomic.Value(u32) = .init(0),
head: std.atomic.Value(u32) = .init(0),
busy: std.atomic.Value(u32) = .init(0),
sleepers: std.atomic.Value(u32) = .init(0),
signal: std.atomic.Value(u32) = .init(0),
stopping: std.atomic.Value(bool) = .init(false),
pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
    return .{ .ring = try allocator.alloc(std.atomic.Value(u32), capacity) };
}

pub fn reserve(self: *Self) ?u32 {
    const tail = self.tail.load(.monotonic);

    return if (tail -% self.head.load(.seq_cst) < capacity) tail else null;
}

pub fn publish(self: *Self, tail: u32, index: u32) void {
    self.ring[tail % capacity].store(index, .monotonic);
    self.tail.store(tail +% 1, .seq_cst);
    self.wake();
}

pub fn drain(self: *Self) void {
    const tail = self.tail.load(.monotonic);
    var head = self.head.load(.seq_cst);

    while (head != tail) head = self.head.cmpxchgWeak(head, tail, .seq_cst, .seq_cst) orelse break;
    while (self.busy.load(.seq_cst) != 0) std.atomic.spinLoopHint();
}

pub fn complete(self: *Self) void {
    _ = self.busy.fetchSub(1, .seq_cst);
}

pub fn stop(self: *Self) void {
    self.stopping.store(true, .seq_cst);
    self.wake();
}

fn wake(self: *Self) void {
    if (self.sleepers.load(.seq_cst) == 0) return;

    _ = self.signal.fetchAdd(1, .seq_cst);

    io().futexWake(u32, &self.signal.raw, std.math.maxInt(u32));
}

pub fn take(self: *Self) ?u32 {
    var idle: usize = 0;

    while (true) {
        if (self.head.load(.seq_cst) != self.tail.load(.seq_cst)) {
            _ = self.busy.fetchAdd(1, .seq_cst);

            const head = self.head.load(.seq_cst);

            if (head != self.tail.load(.seq_cst)) {
                const index = self.ring[head % capacity].load(.monotonic);

                if (self.head.cmpxchgWeak(head, head +% 1, .seq_cst, .monotonic) == null) return index;
            }

            self.complete();

            idle = 0;

            continue;
        }

        if (self.stopping.load(.seq_cst)) return null;

        if (idle < spins) {
            idle += 1;

            std.atomic.spinLoopHint();

            continue;
        }

        _ = self.sleepers.fetchAdd(1, .seq_cst);

        const seen = self.signal.load(.seq_cst);

        if (self.head.load(.seq_cst) == self.tail.load(.seq_cst) and !self.stopping.load(.seq_cst)) io().futexWaitUncancelable(u32, &self.signal.raw, seen);

        _ = self.sleepers.fetchSub(1, .seq_cst);
        idle = 0;
    }
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
