const Project = @import("infer/host.zig").State;
const Derivation = @import("derive/host.zig").State;
const Solver = @import("solve/host.zig").State;
const Mixed = @import("../mixed.zig").Transaction;

const Status = enum(u8) {
    ready,
    yes,
    no,
    out_of_memory,
    invalid_source,
    fn outcome(value: error{ OutOfMemory, InvalidSource }!void) Status {
        value catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidSource => .invalid_source,
        };

        return .ready;
    }
};

fn Operation(comptime State: type, comptime effect: []const u8) type {
    return struct {
        fn run(context: *anyopaque) callconv(.c) Status {
            const state: *State = @ptrCast(@alignCast(context));
            const value = @field(State, effect)(state);

            if (comptime @TypeOf(value) == bool) return if (value) .yes else .no;

            return Status.outcome(value);
        }
    };
}

fn MixedEffect(comptime effect: []const u8, comptime Result: type) type {
    return struct {
        fn run(context: *anyopaque) callconv(.c) Result {
            const state: *Mixed = @ptrCast(@alignCast(context));
            const result = @field(Mixed, effect)(state);

            if (comptime Result != Status) {
                if (comptime Result == u8) return @backingInt(result);

                return result;
            }

            if (comptime @TypeOf(result) == Mixed.Error!bool) {
                return if (result catch |err| return mixedError(err)) .yes else .no;
            }

            result catch |err| return mixedError(err);

            return .ready;
        }
    };
}

fn mixedError(err: Mixed.Error) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidSourceGraph => .invalid_source,
    };
}

comptime {
    @export(&Operation(Project, "normalize").run, .{ .name = "zxcRxProjectNormalizeSources" });
    @export(&Operation(Project, "reuse").run, .{ .name = "zxcRxProjectReuseFrame" });
    @export(&Operation(Project, "derive").run, .{ .name = "zxcRxProjectDeriveFrame" });
    @export(&Operation(Project, "compile").run, .{ .name = "zxcRxProjectCompileBodies" });
    @export(&Operation(Project, "retain").run, .{ .name = "zxcRxProjectRetainStores" });
    @export(&Operation(Project, "publish").run, .{ .name = "zxcRxProjectPublishStores" });
    @export(&Operation(Derivation, "modules").run, .{ .name = "zxcRxProjectPrepareModules" });
    @export(&Operation(Derivation, "graph").run, .{ .name = "zxcRxProjectCollectGraph" });
    @export(&Operation(Derivation, "ordered").run, .{ .name = "zxcRxProjectOrderSignatures" });
    @export(&Operation(Derivation, "reuse").run, .{ .name = "zxcRxProjectReuseSignatures" });
    @export(&Operation(Derivation, "signatures").run, .{ .name = "zxcRxProjectLoadSignatures" });
    @export(&Operation(Derivation, "index").run, .{ .name = "zxcRxProjectIndexSignatures" });
    @export(&Operation(Derivation, "stores").run, .{ .name = "zxcRxProjectLoadStoreRegistry" });
    @export(&Operation(Derivation, "prepare").run, .{ .name = "zxcRxProjectPrepareFlow" });
    @export(&Operation(Derivation, "infer").run, .{ .name = "zxcRxProjectSolveFlow" });
    @export(&Operation(Derivation, "complete").run, .{ .name = "zxcRxProjectCompleteShortcuts" });
    @export(&Operation(Derivation, "publish").run, .{ .name = "zxcRxProjectPublishFrame" });
    @export(&Operation(Solver, "collect").run, .{ .name = "zxcRxProjectCollectConstraints" });
    @export(&Operation(Solver, "finish").run, .{ .name = "zxcRxProjectFinishConstraints" });
    @export(&Operation(Solver, "resolve").run, .{ .name = "zxcRxProjectResolveConstraints" });
    @export(&MixedEffect("active", bool).run, .{ .name = "zxcRxMixedReady" });
    @export(&MixedEffect("prepare", Status).run, .{ .name = "zxcRxMixedPrepareWindow" });
    @export(&MixedEffect("restore", Status).run, .{ .name = "zxcRxMixedRestorePrefix" });
    @export(&MixedEffect("dispatch", u8).run, .{ .name = "zxcRxMixedDispatchBody" });
    @export(&MixedEffect("reject", Status).run, .{ .name = "zxcRxMixedRejectBody" });
    @export(&MixedEffect("analyze", Status).run, .{ .name = "zxcRxMixedAnalyzeBody" });
    @export(&MixedEffect("lower", Status).run, .{ .name = "zxcRxMixedLowerBody" });
    @export(&MixedEffect("record", void).run, .{ .name = "zxcRxMixedRecordBody" });
    @export(&MixedEffect("materialize", Status).run, .{ .name = "zxcRxMixedMaterializeOutput" });
    @export(&MixedEffect("publish", Status).run, .{ .name = "zxcRxMixedPublishExports" });
    @export(&MixedEffect("retain", void).run, .{ .name = "zxcRxMixedRetainHistory" });
}
