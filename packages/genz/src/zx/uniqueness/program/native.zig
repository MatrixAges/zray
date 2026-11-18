extern fn zxcUniquenessReplay(context: *anyopaque, target: *anyopaque, reused: *bool) bool;
extern fn zxcUniquenessOpen(context: *anyopaque) bool;
extern fn zxcUniquenessPrepare(context: *anyopaque, reset: bool, clear: bool, budget: *u64) bool;
extern fn zxcUniquenessSettle(context: *anyopaque, budget: u64, exhausted: *bool) bool;
extern fn zxcUniquenessDemand(context: *anyopaque, changed: *bool) bool;
extern fn zxcUniquenessPlans(context: *anyopaque, target: *anyopaque) bool;
extern fn zxcUniquenessCommit(context: *anyopaque) bool;

const Error = error{OutOfMemory};

pub fn replay(context: *const anyopaque, target: *const anyopaque) Error!bool {
    var reused: bool = false;

    if (!zxcUniquenessReplay(@constCast(context), @constCast(target), &reused)) return error.OutOfMemory;

    return reused;
}

pub fn open(context: *const anyopaque) Error!void {
    if (!zxcUniquenessOpen(@constCast(context))) return error.OutOfMemory;
}

pub fn prepare(context: *const anyopaque, reset: bool, clear: bool) Error!u64 {
    var budget: u64 = 0;

    if (!zxcUniquenessPrepare(@constCast(context), reset, clear, &budget)) return error.OutOfMemory;

    return budget;
}

pub fn settle(context: *const anyopaque, budget: u64) Error!bool {
    var exhausted: bool = false;

    if (!zxcUniquenessSettle(@constCast(context), budget, &exhausted)) return error.OutOfMemory;

    return exhausted;
}

pub fn demand(context: *const anyopaque) Error!bool {
    var changed: bool = false;

    if (!zxcUniquenessDemand(@constCast(context), &changed)) return error.OutOfMemory;

    return changed;
}

pub fn plans(context: *const anyopaque, target: *const anyopaque) Error!void {
    if (!zxcUniquenessPlans(@constCast(context), @constCast(target))) return error.OutOfMemory;
}

pub fn commit(context: *const anyopaque) Error!void {
    if (!zxcUniquenessCommit(@constCast(context))) return error.OutOfMemory;
}
