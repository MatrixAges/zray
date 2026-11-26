const std = @import("std");
const ir = @import("zx").ir;
const Analysis = @import("../function_analysis.zig");
const Uniqueness = Analysis.Uniqueness;
const facts = @import("generated.zig");
const Error = std.mem.Allocator.Error;

pub fn analyze(work: Analysis.BasisBuild, exported: []const ir.FunctionId, concurrent: bool) Error!Analysis {
    var basis = work;
    var thread: ?std.Thread = null;

    defer if (thread) |handle| handle.join();

    if (basis.source == .build) {
        if (concurrent) {
            thread = std.Thread.spawn(.{}, Analysis.BasisBuild.run, .{&basis}) catch null;

            if (thread == null) basis.run();
        } else {
            basis.run();
        }
    }

    const collected = facts.analyze(basis.allocator, basis.workspace, basis.program.*, exported);

    if (thread) |handle| {
        handle.join();

        thread = null;
    }

    const result = try collected;

    try basis.result;

    var output: Analysis = .{
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
        .basis = basis.source.basis(),
    };

    output.uniqueness = if (concurrent)
        try Uniqueness.analyzeConcurrent(basis.allocator, basis.workspace, basis.program.*, exported, output.basis, output.return_allocations, basis.memo)

    else
        try Uniqueness.analyze(basis.allocator, basis.workspace, basis.program.*, exported, output.basis, output.return_allocations, basis.memo);

    output.entry_flags = try entryFlags(basis, &output);

    return output;
}

pub fn reentry(work: Analysis.BasisBuild, output: *Analysis) Error!void {
    output.entry_flags = try entryFlags(work, output);
    output.uniqueness.entry = try Uniqueness.analyzeEntry(work.allocator, work.workspace, work.program.*, output.basis);
}

fn entryFlags(work: Analysis.BasisBuild, value: *const Analysis) Error!Analysis.Entry.Flags {
    return Analysis.Entry.analyze(work.workspace, work.program.*, .{
        .local = value.value.local,
        .pure = value.value.pure,
        .io = value.io,
        .process = value.process,
        .tasks = value.tasks,
    });
}
