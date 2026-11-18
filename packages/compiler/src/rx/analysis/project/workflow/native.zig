const Error = error{ OutOfMemory, InvalidSource };

const Status = enum(u8) {
    ready,
    yes,
    no,
    out_of_memory,
    invalid_source,
    fn check(self: Status) Error!void {
        switch (self) {
            .ready, .yes, .no => {},
            .out_of_memory => return error.OutOfMemory,
            .invalid_source => return error.InvalidSource,
        }
    }
};

const Operation = fn (*anyopaque) callconv(.c) Status;

fn Checked(comptime operation: Operation) type {
    return struct {
        fn run(context: *const anyopaque) Error!void {
            try operation(@constCast(context)).check();
        }
    };
}

extern fn zxcRxProjectNormalizeSources(context: *anyopaque) Status;
extern fn zxcRxProjectReuseFrame(context: *anyopaque) Status;
extern fn zxcRxProjectDeriveFrame(context: *anyopaque) Status;
extern fn zxcRxProjectCompileBodies(context: *anyopaque) Status;
extern fn zxcRxProjectRetainStores(context: *anyopaque) Status;
extern fn zxcRxProjectPublishStores(context: *anyopaque) Status;
extern fn zxcRxProjectPrepareModules(context: *anyopaque) Status;
extern fn zxcRxProjectCollectGraph(context: *anyopaque) Status;
extern fn zxcRxProjectOrderSignatures(context: *anyopaque) Status;
extern fn zxcRxProjectReuseSignatures(context: *anyopaque) Status;
extern fn zxcRxProjectLoadSignatures(context: *anyopaque) Status;
extern fn zxcRxProjectIndexSignatures(context: *anyopaque) Status;
extern fn zxcRxProjectLoadStoreRegistry(context: *anyopaque) Status;
extern fn zxcRxProjectPrepareFlow(context: *anyopaque) Status;
extern fn zxcRxProjectSolveFlow(context: *anyopaque) Status;
extern fn zxcRxProjectCompleteShortcuts(context: *anyopaque) Status;
extern fn zxcRxProjectPublishFrame(context: *anyopaque) Status;
extern fn zxcRxProjectCollectConstraints(context: *anyopaque) Status;
extern fn zxcRxProjectFinishConstraints(context: *anyopaque) Status;
extern fn zxcRxProjectResolveConstraints(context: *anyopaque) Status;

pub const normalizeSources = Checked(zxcRxProjectNormalizeSources).run;

pub fn reuseFrame(context: *const anyopaque) bool {
    return zxcRxProjectReuseFrame(@constCast(context)) == .yes;
}

pub const deriveFrame = Checked(zxcRxProjectDeriveFrame).run;
pub const compileBodies = Checked(zxcRxProjectCompileBodies).run;
pub const retainStores = Checked(zxcRxProjectRetainStores).run;
pub const publishStores = Checked(zxcRxProjectPublishStores).run;
pub const prepareModules = Checked(zxcRxProjectPrepareModules).run;
pub const collectGraph = Checked(zxcRxProjectCollectGraph).run;
pub const orderSignatures = Checked(zxcRxProjectOrderSignatures).run;

pub fn reuseSignatures(context: *const anyopaque) bool {
    return zxcRxProjectReuseSignatures(@constCast(context)) == .yes;
}

pub const loadSignatures = Checked(zxcRxProjectLoadSignatures).run;
pub const indexSignatures = Checked(zxcRxProjectIndexSignatures).run;
pub const loadStoreRegistry = Checked(zxcRxProjectLoadStoreRegistry).run;
pub const prepareFlow = Checked(zxcRxProjectPrepareFlow).run;
pub const solveFlow = Checked(zxcRxProjectSolveFlow).run;
pub const completeShortcuts = Checked(zxcRxProjectCompleteShortcuts).run;
pub const publishFrame = Checked(zxcRxProjectPublishFrame).run;
pub const collectConstraints = Checked(zxcRxProjectCollectConstraints).run;
pub const finishConstraints = Checked(zxcRxProjectFinishConstraints).run;
pub const resolveConstraints = Checked(zxcRxProjectResolveConstraints).run;

extern fn zxcRxMixedReady(context: *anyopaque) bool;
extern fn zxcRxMixedPrepareWindow(context: *anyopaque) Status;
extern fn zxcRxMixedRestorePrefix(context: *anyopaque) Status;
extern fn zxcRxMixedDispatchBody(context: *anyopaque) u8;
extern fn zxcRxMixedRejectBody(context: *anyopaque) Status;
extern fn zxcRxMixedAnalyzeBody(context: *anyopaque) Status;
extern fn zxcRxMixedLowerBody(context: *anyopaque) Status;
extern fn zxcRxMixedRecordBody(context: *anyopaque) void;
extern fn zxcRxMixedMaterializeOutput(context: *anyopaque) Status;
extern fn zxcRxMixedPublishExports(context: *anyopaque) Status;
extern fn zxcRxMixedRetainHistory(context: *anyopaque) void;

pub fn ready(context: *const anyopaque) bool {
    return zxcRxMixedReady(@constCast(context));
}

pub const prepareWindow = Checked(zxcRxMixedPrepareWindow).run;

pub fn restorePrefix(context: *const anyopaque) Error!bool {
    const outcome = zxcRxMixedRestorePrefix(@constCast(context));

    try outcome.check();

    return outcome == .yes;
}

pub fn dispatchBody(context: *const anyopaque) u8 {
    return zxcRxMixedDispatchBody(@constCast(context));
}

pub const rejectBody = Checked(zxcRxMixedRejectBody).run;
pub const analyzeBody = Checked(zxcRxMixedAnalyzeBody).run;
pub const lowerBody = Checked(zxcRxMixedLowerBody).run;

pub fn recordBody(context: *const anyopaque) void {
    zxcRxMixedRecordBody(@constCast(context));
}

pub const materializeOutput = Checked(zxcRxMixedMaterializeOutput).run;
pub const publishExports = Checked(zxcRxMixedPublishExports).run;

pub fn retainHistory(context: *const anyopaque) void {
    zxcRxMixedRetainHistory(@constCast(context));
}
