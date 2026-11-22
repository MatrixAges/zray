const std = @import("std");

inline fn word(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!*u32 {
    const words: *const []u32 = @ptrCast(@alignCast(target));

    if (index >= words.len) return error.IndexOutOfBounds;

    return &words.*[@intCast(index)];
}

pub inline fn loadU32Acquire(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return @atomicLoad(u32, try word(target, index), .acquire);
}

pub inline fn storeU32Release(target: *const anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    @atomicStore(u32, try word(target, index), value, .release);
}

pub inline fn compareExchangeU32Acquire(target: *const anyopaque, index: u64, expected: u32, value: u32) error{IndexOutOfBounds}!bool {
    return @cmpxchgStrong(u32, try word(target, index), expected, value, .acquire, .monotonic) == null;
}

pub inline fn exchangeU32Release(target: *const anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!u32 {
    return @atomicRmw(u32, try word(target, index), .Xchg, value, .release);
}

pub inline fn waitU32(target: *const anyopaque, index: u64, expected: u32) error{IndexOutOfBounds}!void {
    std.Io.Threaded.global_single_threaded.io().futexWaitUncancelable(u32, try word(target, index), expected);
}

pub inline fn wakeOneU32(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!void {
    std.Io.Threaded.global_single_threaded.io().futexWake(u32, try word(target, index), 1);
}

pub inline fn loadU32Sequential(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return @atomicLoad(u32, try word(target, index), .seq_cst);
}

pub inline fn loadU32Relaxed(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return @atomicLoad(u32, try word(target, index), .monotonic);
}

pub inline fn storeU32Sequential(target: *const anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    @atomicStore(u32, try word(target, index), value, .seq_cst);
}

pub inline fn storeU32Relaxed(target: *const anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    @atomicStore(u32, try word(target, index), value, .monotonic);
}

pub inline fn compareExchangeU32Sequential(target: *const anyopaque, index: u64, expected: u32, value: u32) error{IndexOutOfBounds}!bool {
    return @cmpxchgStrong(u32, try word(target, index), expected, value, .seq_cst, .seq_cst) == null;
}

pub inline fn addU32Sequential(target: *const anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    _ = @atomicRmw(u32, try word(target, index), .Add, value, .seq_cst);
}

pub inline fn wakeAllU32(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!void {
    std.Io.Threaded.global_single_threaded.io().futexWake(u32, try word(target, index), std.math.maxInt(u32));
}

pub inline fn spinHint() void {
    std.atomic.spinLoopHint();
}

pub inline fn fetchAddIndexRelaxed(target: *const anyopaque, amount: u64) u64 {
    const index: *std.atomic.Value(usize) = @ptrCast(@alignCast(@constCast(target)));

    return index.fetchAdd(@intCast(amount), .monotonic);
}
