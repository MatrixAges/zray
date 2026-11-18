const Project = @import("infer/host.zig").State;
const Derivation = @import("derive/host.zig").State;
const Solver = @import("solve/host.zig").State;

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
}
