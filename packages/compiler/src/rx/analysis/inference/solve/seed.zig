const zx = @import("zx");
const host = @import("host.zig");
const bindings = @import("../bindings.zig");
const non_null = @import("../non_null.zig");

pub fn run(frame: *host.Frame) zx.Error!void {
    while (true) {
        const revision = host.solveRevision(frame);

        try bindings.validateUsesSeed(frame.graph);
        try bindings.propagateSeed(frame.graph, false);
        try non_null.propagateSeed(frame.graph, false);
        try host.solveSequences(frame);

        _ = try host.solveConstructions(frame, false);
        _ = try host.solveSelections(frame, false);

        try host.solveLengths(frame);
        if (try host.solveIndexes(frame, revision)) continue;
        if (try host.solveAssignmentClasses(frame)) continue;
        if (try host.solveSequenceDefaults(frame)) continue;
        if (try host.solveMaterializeAssignments(frame)) continue;
        if (try host.solveIndexDefaults(frame)) continue;

        const final_revision = frame.graph.revision;

        try non_null.propagateSeed(frame.graph, true);
        if (frame.graph.revision != final_revision) continue;
        if (try host.solveSelections(frame, true)) continue;
        if (try host.solveConstructions(frame, true)) continue;
        try host.solveValidateLengths(frame);
        try bindings.propagateSeed(frame.graph, true);
        try host.solveValidateAssignments(frame);

        return;
    }
}
