const zx = @import("zx");
const Assignment = @import("../assignment.zig");
const defaults = @import("../sequences/defaults/seed.zig");
const host = @import("host.zig");
const Construction = @import("../construction.zig");
const Selection = @import("../selection.zig");
const Sequences = @import("../sequences.zig");
const bindings = @import("../bindings.zig");
const non_null = @import("../non_null.zig");
const lengths = @import("../projections/seed.zig");
const indexes = @import("../index/seed.zig");

pub fn run(frame: *host.Frame) zx.Error!void {
    while (true) {
        const revision = frame.graph.revision;

        try bindings.validateUsesSeed(frame.graph);
        try bindings.propagateSeed(frame.graph, false);
        try non_null.propagateSeed(frame.graph, false);
        try Sequences.replaySeed(frame.graph);
        try Construction.replaySeed(frame.graph, false);
        try Selection.replaySeed(frame.graph, false);
        try lengths.replay(frame.graph);
        try indexes.replay(frame.graph);
        if (frame.graph.revision != revision) continue;

        _ = frame.workspace.reset(.retain_capacity);
        const allocator = frame.workspace.allocator();
        const classes = try Assignment.Base.init(frame.graph, allocator);

        try classes.propagate(frame.graph);
        if (frame.graph.revision != revision) continue;
        if (try defaults.apply(frame.graph, classes)) continue;
        try Assignment.materializeSeed(frame.graph, classes, allocator);
        if (frame.graph.revision != revision) continue;
        if (try indexes.defaultLists(frame.graph)) continue;

        const final_revision = frame.graph.revision;

        try non_null.propagateSeed(frame.graph, true);
        if (frame.graph.revision != final_revision) continue;
        try Selection.replaySeed(frame.graph, true);
        if (frame.graph.revision != final_revision) continue;
        try Construction.replaySeed(frame.graph, true);
        if (frame.graph.revision != final_revision) continue;
        try lengths.validate(frame.graph);
        try bindings.propagateSeed(frame.graph, true);
        try Assignment.validateSeed(frame.graph);

        return;
    }
}
