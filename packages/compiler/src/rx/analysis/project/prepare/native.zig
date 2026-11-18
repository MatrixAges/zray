const Status = enum(u8) {
    ready,
    out_of_memory,
    invalid_flow,
    fn check(self: Status) error{ OutOfMemory, InvalidFlow }!void {
        return switch (self) {
            .ready => {},
            .out_of_memory => error.OutOfMemory,
            .invalid_flow => error.InvalidFlow,
        };
    }
};

extern fn zxcRxPrepareBeginModule(context: *const anyopaque, row: u64) Status;
extern fn zxcRxPrepareResolveStores(context: *const anyopaque) Status;
extern fn zxcRxPreparePrepareBody(context: *const anyopaque) Status;
extern fn zxcRxPrepareImportTypes(context: *const anyopaque) Status;
extern fn zxcRxPreparePublishModule(context: *const anyopaque) Status;
extern fn zxcRxPrepareScanCall(context: *const anyopaque) void;
extern fn zxcRxPrepareParseArgument(context: *const anyopaque) Status;
extern fn zxcRxPrepareAuthorizeCall(context: *const anyopaque) Status;
extern fn zxcRxPrepareResolveCallee(context: *const anyopaque) Status;
extern fn zxcRxPreparePublishCall(context: *const anyopaque) Status;
extern fn zxcRxPrepareRecordArgument(context: *const anyopaque) Status;
extern fn zxcRxPrepareBindCall(context: *const anyopaque, slot: u64, item: u32) Status;
extern fn zxcRxPrepareBindResult(context: *const anyopaque, slot: u64, item: u32) void;
extern fn zxcRxPrepareBindTaskResult(context: *const anyopaque, slot: u64, item: u32) void;
extern fn zxcRxPrepareBindTask(context: *const anyopaque, slot: u64, item: u32, first: u32, count: u32, output: bool) void;
extern fn zxcRxPrepareBindParallelTask(context: *const anyopaque, slot: u64, item: u32, first: u32, count: u32, task_id: u64) void;
extern fn zxcRxPrepareBindGroup(context: *const anyopaque, item: u32, first: u32, count: u32) void;
extern fn zxcRxPrepareBindSelection(context: *const anyopaque, slot: u64, item: u32, conditional: bool, else_branch: bool) Status;
extern fn zxcRxPrepareTaskReturns(context: *const anyopaque, slot: u64) Status;
extern fn zxcRxPrepareUnreachableStep(context: *const anyopaque, slot: u64) Status;
extern fn zxcRxPrepareUnsupportedStep(context: *const anyopaque, slot: u64) Status;

pub fn beginModule(context: *const anyopaque, row: u64) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareBeginModule(context, row).check();
}

pub fn resolveStores(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareResolveStores(context).check();
}

pub fn prepareBody(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPreparePrepareBody(context).check();
}

pub fn importTypes(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareImportTypes(context).check();
}

pub fn publishModule(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPreparePublishModule(context).check();
}

pub const scanCall = zxcRxPrepareScanCall;

pub fn parseArgument(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareParseArgument(context).check();
}

pub fn authorizeCall(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareAuthorizeCall(context).check();
}

pub fn resolveCallee(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareResolveCallee(context).check();
}

pub fn publishCall(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPreparePublishCall(context).check();
}

pub fn recordArgument(context: *const anyopaque) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareRecordArgument(context).check();
}

pub fn bindCall(context: *const anyopaque, slot: u64, item: u32) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareBindCall(context, slot, item).check();
}

pub const bindResult = zxcRxPrepareBindResult;
pub const bindTaskResult = zxcRxPrepareBindTaskResult;
pub const bindTask = zxcRxPrepareBindTask;
pub const bindParallelTask = zxcRxPrepareBindParallelTask;
pub const bindGroup = zxcRxPrepareBindGroup;

pub fn bindSelection(context: *const anyopaque, slot: u64, item: u32, conditional: bool, else_branch: bool) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareBindSelection(context, slot, item, conditional, else_branch).check();
}

pub fn taskReturns(context: *const anyopaque, slot: u64) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareTaskReturns(context, slot).check();
}

pub fn unreachableStep(context: *const anyopaque, slot: u64) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareUnreachableStep(context, slot).check();
}

pub fn unsupportedStep(context: *const anyopaque, slot: u64) error{ OutOfMemory, InvalidFlow }!void {
    try zxcRxPrepareUnsupportedStep(context, slot).check();
}
