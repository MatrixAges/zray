const std = @import("std");
const ir = @import("zx").ir;
const Analysis = @import("../function_analysis.zig");
const Uniqueness = Analysis.Uniqueness;
const facts = @import("generated.zig");
const failure = @import("../construction/publication.zig").failure;
const Error = std.mem.Allocator.Error;

pub fn analyze(work: Analysis.BasisBuild, exported: []const ir.FunctionId, concurrent: bool) Error!Analysis {
    const entry = @import("generated_analysis_workflow");
    const input: std.meta.Child(entry.Input) = .{ .build = work.source == .build, .concurrent = concurrent };
    var scheduler = std.heap.ArenaAllocator.init(work.workspace);

    defer scheduler.deinit();

    const steps = entry.executeIn(scheduler.allocator(), &input) catch |err| return failure(err);
    var output: Analysis = undefined;

    try run(work, exported, &output, steps);

    return output;
}

pub fn reentry(work: Analysis.BasisBuild, output: *Analysis) Error!void {
    const entry = @import("generated_analysis_reentry");
    var scheduler = std.heap.ArenaAllocator.init(work.workspace);

    defer scheduler.deinit();

    const steps = entry.executeIn(scheduler.allocator(), {}) catch |err| return failure(err);

    try run(work, &.{}, output, steps);
}

fn run(work: Analysis.BasisBuild, exported: []const ir.FunctionId, output: *Analysis, steps: anytype) Error!void {
    var basis = work;
    var thread: ?std.Thread = null;

    defer if (thread) |worker| worker.join();

    for (steps) |step| switch (step) {
        .StartBasis => {
            thread = std.Thread.spawn(.{}, Analysis.BasisBuild.run, .{&basis}) catch null;

            if (thread == null) basis.run();
        },
        .BuildBasis => basis.run(),
        .CollectFacts => output.* = try collect(work, exported),
        .JoinBasis => {
            if (thread) |worker| worker.join();

            thread = null;

            try basis.result;
        },
        .PlanSerial => output.uniqueness = try Uniqueness.analyze(work.allocator, work.workspace, work.program.*, exported, output.basis, output.return_allocations, work.memo),
        .PlanConcurrent => output.uniqueness = try Uniqueness.analyzeConcurrent(work.allocator, work.workspace, work.program.*, exported, output.basis, output.return_allocations, work.memo),
        .AnalyzeFlags => output.entry_flags = try Analysis.Entry.analyze(work.workspace, work.program.*, .{
            .local = output.value.local,
            .pure = output.value.pure,
            .io = output.io,
            .process = output.process,
            .tasks = output.tasks,
        }),
        .PlanEntry => output.uniqueness.entry = try Uniqueness.analyzeEntry(work.allocator, work.workspace, work.program.*, output.basis),
    };
}

fn collect(work: Analysis.BasisBuild, exported: []const ir.FunctionId) Error!Analysis {
    const result = try facts.analyze(work.allocator, work.workspace, work.program.*, exported);

    return .{
        .value = result.value,
        .entry_flags = undefined,
        .io = result.io,
        .process = result.process,
        .tasks = result.tasks,
        .errors = result.errors,
        .return_allocations = result.return_allocations,
        .layout_types = result.layout_types,
        .identity_free = result.identity_free,
        .fresh_outputs = result.fresh_outputs,
        .constructed_outputs = result.constructed_outputs,
        .grows = result.grows,
        .uniqueness = undefined,
        .basis = work.source.basis(),
    };
}
