const Error = error{ InvalidFlow, InvalidSource, OutOfMemory };

const Status = enum(u8) {
    ready,
    out_of_memory,
    invalid_flow,
    invalid_source,
    fn check(self: Status) Error!void {
        return switch (self) {
            .ready => {},
            .out_of_memory => error.OutOfMemory,
            .invalid_flow => error.InvalidFlow,
            .invalid_source => error.InvalidSource,
        };
    }
};

const Move = fn (*anyopaque, bool, u64) callconv(.c) Status;
const Close = fn (*anyopaque, bool) callconv(.c) Status;

extern fn zxcPreparedFlowObserve(context: *anyopaque, compiling: bool, target: *[2]u64) u8;
extern fn zxcPreparedFlowCalls(context: *anyopaque, compiling: bool, next: u64) Status;
extern fn zxcPreparedFlowResult(context: *anyopaque, compiling: bool, next: u64) Status;
extern fn zxcPreparedFlowTask(context: *anyopaque, compiling: bool, next: u64, parallel: bool) Status;
extern fn zxcPreparedFlowParallel(context: *anyopaque, compiling: bool, next: u64) Status;
extern fn zxcPreparedFlowSelection(context: *anyopaque, compiling: bool, next: u64) Status;
extern fn zxcPreparedFlowOpenCase(context: *anyopaque, compiling: bool, next: u64) Status;
extern fn zxcPreparedFlowCloseTask(context: *anyopaque, compiling: bool, parallel: bool) Status;
extern fn zxcPreparedFlowCloseParallel(context: *anyopaque, compiling: bool) Status;
extern fn zxcPreparedFlowCloseSelection(context: *anyopaque, compiling: bool) Status;
extern fn zxcPreparedFlowCloseCase(context: *anyopaque, compiling: bool) Status;
extern fn zxcPreparedFlowPop(context: *anyopaque, compiling: bool) void;

pub fn observe(context: *const anyopaque, compiling: bool, target: *const anyopaque) u8 {
    return zxcPreparedFlowObserve(@constCast(context), compiling, @ptrCast(@alignCast(@constCast(target))));
}

fn Moving(comptime effect: Move) type {
    return struct {
        fn call(context: *const anyopaque, compiling: bool, next: u64) Error!void {
            try effect(@constCast(context), compiling, next).check();
        }
    };
}

pub const calls = Moving(zxcPreparedFlowCalls).call;
pub const result = Moving(zxcPreparedFlowResult).call;
pub const parallel = Moving(zxcPreparedFlowParallel).call;
pub const selection = Moving(zxcPreparedFlowSelection).call;
pub const openCase = Moving(zxcPreparedFlowOpenCase).call;

pub fn task(context: *const anyopaque, compiling: bool, next: u64, parallel_task: bool) Error!void {
    try zxcPreparedFlowTask(@constCast(context), compiling, next, parallel_task).check();
}

pub fn closeTask(context: *const anyopaque, compiling: bool, parallel_task: bool) Error!void {
    try zxcPreparedFlowCloseTask(@constCast(context), compiling, parallel_task).check();
}

fn Closing(comptime effect: Close) type {
    return struct {
        fn call(context: *const anyopaque, compiling: bool) Error!void {
            try effect(@constCast(context), compiling).check();
        }
    };
}

pub const closeParallel = Closing(zxcPreparedFlowCloseParallel).call;
pub const closeSelection = Closing(zxcPreparedFlowCloseSelection).call;
pub const closeCase = Closing(zxcPreparedFlowCloseCase).call;

pub fn pop(context: *const anyopaque, compiling: bool) void {
    zxcPreparedFlowPop(@constCast(context), compiling);
}
