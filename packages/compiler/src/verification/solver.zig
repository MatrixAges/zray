const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");

pub const Options = struct {
    solver: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub fn check(io: std.Io, backing_allocator: std.mem.Allocator, program: zx.ir.Program, sources: []const frontend.project.Source, entry: []const u8, options: Options, writer: *std.Io.Writer) !bool {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var generated = try @import("root.zig").generate(backing_allocator, program);

    defer generated.deinit();

    if (generated.value == .diagnostic) {
        try writer.print("verification: {s}\n", .{generated.value.diagnostic.message});

        return false;
    }

    const query = generated.value.query;
    const evidence = try std.json.Stringify.valueAlloc(allocator, .{ .sources = sources, .entry = entry, .ir_version = program.version, .types = program.types, .inputs = query.inputs, .ir = program }, .{ .whitespace = .indent_2 });
    var hash: [32]u8 = undefined;
    var fingerprint = std.crypto.hash.sha2.Sha256.init(.{});

    fingerprint.update(evidence);
    fingerprint.update(query.feasibility);
    fingerprint.update(query.correctness);
    fingerprint.final(&hash);

    const correctness_path = options.output orelse try std.fmt.allocPrint(allocator, ".zxc/proofs/{s}/correctness.smt2", .{std.fmt.bytesToHex(hash, .lower)});
    const solver = options.solver orelse "z3";

    if (comptime !@import("parser_options").generated_parser) return @import("solver/seed.zig").check(io, allocator, query, evidence, correctness_path, solver, writer);

    const workflow = @import("generated_verification_solver");

    const report = try workflow.executeIn(allocator, &.{
        .solver = solver,
        .path = correctness_path,
        .evidence = evidence,
        .feasibility = query.feasibility,
        .correctness = query.correctness,
    }, io);

    switch (report.verdict) {
        .Proved => {
            try writer.print("verified: entry paths satisfy supported safety obligations and reached contracts; query: {s}\n", .{correctness_path});

            return true;
        },
        .Counterexample => {
            try writer.print("verification failed: counterexample\n{s}\n", .{report.model});
            for (query.inputs) |input| try writer.print("{s} = {s}\n", .{ input.symbol, input.path });
        },
        .Infeasible => try writer.print("verification not proved: preconditions are {s}\n", .{report.status}),
        .Unknown => try writer.print("verification not proved: {s}\n", .{report.status}),
        .VersionFailed => return error.SolverVersionFailed,
        .SolverFailed => return error.SolverFailed,
        .InvalidResponse => return error.InvalidSolverResponse,
        .Continue => unreachable,
    }

    return false;
}
