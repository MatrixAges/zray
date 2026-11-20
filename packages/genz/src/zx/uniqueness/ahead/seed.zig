const std = @import("std");
const State = enum(u32) { idle, queued, running, waiting, ready, failed, held };
pub const Event = enum { Queue, Hold, Withdraw, Claim, Complete, Fail };
pub const Step = enum { CheckMemo, Reserve, Submit, WithdrawOnFull, Claim, ReadGrowth, AnalyzeDeferred, AnalyzePlan, Publish, Complete, Wait, CheckReads };

pub fn steps(comptime activity: anytype, comptime kind: @import("../memo.zig").Kind, comptime persistent: bool) []const Step {
    return switch (activity) {
        .Request => if (kind == .planned and !persistent)
            &.{ .Reserve, .Submit, .WithdrawOnFull }
        else
            &.{ .CheckMemo, .Reserve, .Submit, .WithdrawOnFull },
        .Analyze => switch (kind) {
            .settled => &.{ .Claim, .AnalyzeDeferred, .Publish, .Complete },
            .demanded => &.{ .Claim, .ReadGrowth, .AnalyzeDeferred, .Publish, .Complete },
            .planned => &.{ .Claim, .AnalyzePlan, .Publish, .Complete },
        },
        .Collect => if (kind == .planned) &.{.Wait} else &.{ .Wait, .CheckReads },
    };
}

fn cells(words: []u32) []std.atomic.Value(State) {
    return @ptrCast(words);
}

pub fn scan(words: []u32, dirty: []bool, recursive: []const bool, indices: @import("../work/round.zig").Window, first: usize, workers: usize) ?usize {
    const end = @min(indices.first.len + indices.second.len, workers * 16);

    for (first..end) |pos| {
        const index = indices.at(pos);

        switch (cells(words)[index].load(.acquire)) {
            .idle => {},
            .ready, .held => if (!dirty[index]) continue,
            .queued => {
                dirty[index] = false;

                continue;
            },
            .running, .waiting, .failed => continue,
        }

        if (recursive[index]) continue;

        dirty[index] = false;

        return pos;
    }

    return null;
}

pub fn transition(words: []u32, index: usize, event: Event) bool {
    const state = &cells(words)[index];

    switch (event) {
        .Claim => return state.cmpxchgStrong(.queued, .running, .acquire, .monotonic) == null,
        .Withdraw => return state.cmpxchgStrong(.queued, .idle, .acquire, .monotonic) == null,
        .Queue, .Hold => state.store(if (event == .Queue) .queued else .held, .release),
        .Complete, .Fail => {
            if (state.swap(if (event == .Complete) .ready else .failed, .release) == .waiting)
                std.Io.Threaded.global_single_threaded.io().futexWake(State, &state.raw, 1);
        },
    }

    return true;
}

pub fn take(words: []u32, dirty: []bool, index: usize) std.mem.Allocator.Error!bool {
    const state = &cells(words)[index];

    dirty[index] = false;

    defer state.store(.idle, .release);

    while (true) {
        switch (state.load(.acquire)) {
            .idle, .held => return false,
            .queued => if (state.cmpxchgStrong(.queued, .idle, .acquire, .monotonic) == null) return false,
            .running => _ = state.cmpxchgStrong(.running, .waiting, .acquire, .monotonic),
            .waiting => std.Io.Threaded.global_single_threaded.io().futexWaitUncancelable(State, &state.raw, .waiting),
            .ready => return true,
            .failed => return error.OutOfMemory,
        }
    }
}

pub fn reset(words: []u32, dirty: []bool) void {
    @memset(cells(words), .init(.idle));
    @memset(dirty, false);
}
