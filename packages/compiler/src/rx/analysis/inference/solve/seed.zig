const zx = @import("zx");
const host = @import("host.zig");
const bindings = @import("../bindings.zig");

pub fn run(frame: *host.Frame) zx.Error!void {
    while (true) {
        const revision = host.solveRevision(frame);

        try bindings.validateUsesSeed(frame.graph);
        try bindings.propagateSeed(frame.graph, false);

        _ = try host.solveNonNull(frame, false);

        try host.solveSequences(frame);

        _ = try host.solveConstructions(frame, false);
        _ = try host.solveSelections(frame, false);

        try host.solveLengths(frame);
        if (try host.solveIndexes(frame, revision)) continue;
        if (try host.solveAssignmentClasses(frame)) continue;
        if (try host.solveSequenceDefaults(frame)) continue;
        if (try host.solveMaterializeAssignments(frame)) continue;
        if (try host.solveIndexDefaults(frame)) continue;
        if (try host.solveNonNull(frame, true)) continue;
        if (try host.solveSelections(frame, true)) continue;
        if (try host.solveConstructions(frame, true)) continue;
        try host.solveValidateLengths(frame);
        try bindings.propagateSeed(frame.graph, true);
        try host.solveValidateAssignments(frame);

        return;
    }
}
