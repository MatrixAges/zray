const std = @import("std");
const ir = @import("zx").ir;
const Analysis = @import("../function_analysis.zig");
const Uniqueness = Analysis.Uniqueness;
const facts = @import("generated.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Error = std.mem.Allocator.Error;

const Frame = struct {
    basis: Analysis.BasisBuild,
    exported: []const ir.FunctionId,
    output: *Analysis,
    thread: ?std.Thread = null,
    facts_result: Error!void = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
    fn collect(self: *Frame) Error!void {
        const work = &self.basis;
        const result = try facts.analyze(work.allocator, work.workspace, work.program.*, self.exported);

        self.output.* = .{
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

    fn join(self: *Frame) void {
        if (self.thread) |thread| {
            thread.join();

            self.thread = null;
        }
    }

    fn plan(self: *Frame, comptime concurrent: bool) Error!void {
        const work = &self.basis;
        const run = if (concurrent) Uniqueness.analyzeConcurrent else Uniqueness.analyze;
        self.output.uniqueness = try run(work.allocator, work.workspace, work.program.*, self.exported, self.output.basis, self.output.return_allocations, work.memo);
    }
};

pub fn analyze(work: Analysis.BasisBuild, exported: []const ir.FunctionId, concurrent: bool) Error!Analysis {
    var output: Analysis = undefined;
    var frame: Frame = .{ .basis = work, .exported = exported, .output = &output };

    defer frame.join();

    const entry = @import("generated_analysis_workflow");

    const input: std.meta.Child(entry.Input) = .{
        .work = @ptrCast(&frame),
        .build = work.source == .build,
        .concurrent = concurrent,
    };

    try evaluation.execute(entry, &input);

    return output;
}

pub fn reentry(work: Analysis.BasisBuild, output: *Analysis) Error!void {
    const entry = @import("generated_analysis_reentry");
    var frame: Frame = .{ .basis = work, .exported = &.{}, .output = output };

    try evaluation.execute(entry, @ptrCast(&frame));
}

pub fn startAnalysisBasis(handle: *anyopaque) bool {
    const frame = Frame.borrow(handle);

    frame.thread = std.Thread.spawn(.{}, Analysis.BasisBuild.run, .{&frame.basis}) catch return false;

    return true;
}

pub fn buildAnalysisBasis(handle: *anyopaque) void {
    Frame.borrow(handle).basis.run();
}

pub fn collectAnalysisFacts(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.facts_result = frame.collect();
}

pub fn joinAnalysisBasis(handle: *anyopaque) void {
    Frame.borrow(handle).join();
}

pub fn checkAnalysisFacts(handle: *anyopaque) Error!void {
    return Frame.borrow(handle).facts_result;
}

pub fn checkAnalysisBasis(handle: *anyopaque) Error!void {
    return Frame.borrow(handle).basis.result;
}

pub fn planAnalysis(handle: *anyopaque) Error!void {
    return Frame.borrow(handle).plan(false);
}

pub fn planAnalysisConcurrent(handle: *anyopaque) Error!void {
    return Frame.borrow(handle).plan(true);
}

pub fn analyzeEntryFlags(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const value = frame.output;

    value.entry_flags = try Analysis.Entry.analyze(frame.basis.workspace, frame.basis.program.*, .{
        .local = value.value.local,
        .pure = value.value.pure,
        .io = value.io,
        .process = value.process,
        .tasks = value.tasks,
    });
}

pub fn analyzeIndependentEntry(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const work = &frame.basis;
    frame.output.uniqueness.entry = try Uniqueness.analyzeEntry(work.allocator, work.workspace, work.program.*, frame.output.basis);
}
