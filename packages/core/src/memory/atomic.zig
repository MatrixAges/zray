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
