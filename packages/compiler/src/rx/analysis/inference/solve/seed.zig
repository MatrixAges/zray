const zx = @import("zx");
const host = @import("host.zig");
const bindings = @import("../bindings.zig");
const non_null = @import("../non_null.zig");
const lengths = @import("../projections/seed.zig");
const indexes = @import("../index/seed.zig");

pub fn run(frame: *host.Frame) zx.Error!void {
    while (true) {
        const revision = host.solveRevision(frame);

        try bindings.validateUsesSeed(frame.graph);
        try bindings.propagateSeed(frame.graph, false);
        try non_null.propagateSeed(frame.graph, false);
        try host.solveSequences(frame);

        _ = try host.solveConstructions(frame, false);
        _ = try host.solveSelections(frame, false);

        try lengths.replay(frame.graph);
        try indexes.replay(frame.graph);
        if (frame.graph.revision != revision) continue;
        if (try host.solveAssignmentClasses(frame)) continue;
        if (try host.solveSequenceDefaults(frame)) continue;
        if (try host.solveMaterializeAssignments(frame)) continue;
        if (try indexes.defaultLists(frame.graph)) continue;

        const final_revision = frame.graph.revision;

        try non_null.propagateSeed(frame.graph, true);
        if (frame.graph.revision != final_revision) continue;
        if (try host.solveSelections(frame, true)) continue;
        if (try host.solveConstructions(frame, true)) continue;
        try lengths.validate(frame.graph);
        try bindings.propagateSeed(frame.graph, true);
        try host.solveValidateAssignments(frame);

        return;
    }
}
