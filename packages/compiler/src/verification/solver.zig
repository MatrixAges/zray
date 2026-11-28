const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const Conditions = @import("conditions.zig");
const evidence_json = @import("solver/evidence.zig");

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

    const proof = @import("generated_publish_verification_proof");

    const query = switch (generated.value) {
        .query => |query| query,
        .diagnostic => Conditions.Query{ .feasibility = "", .correctness = "", .inputs = &.{} },
    };

    const symbols = zx.memory.borrowTextColumn("symbol", query.inputs);
    const paths = zx.memory.borrowTextColumn("path", query.inputs);
    const Request = std.meta.Child(proof.Input);
    const EvidenceInput = std.meta.Child(@FieldType(Request, "evidence"));

    const evidence = if (generated.value == .query)
        try evidence_json.encode(EvidenceInput, allocator, sources, entry, query.inputs, &program)
    else
        EvidenceInput{ .sources = "", .entry = "", .version = "", .types = "", .inputs = "", .program = "" };

    const input: Request = .{
        .diagnostic = if (generated.value == .diagnostic) generated.value.diagnostic.message else null,
        .output = options.output,
        .solver = options.solver,
        .feasibility = query.feasibility,
        .correctness = query.correctness,
        .bindings = &.{ .symbols = @ptrCast(&symbols), .paths = @ptrCast(&paths), .count = query.inputs.len },
        .evidence = &evidence,
    };

    const report = try proof.executeIn(allocator, &input, io);

    for (report.fragments) |fragment| try writer.writeAll(fragment);

    return switch (report.verdict) {
        .Proved => true,
        .Unsupported, .Counterexample, .Infeasible, .Unknown => false,
        .VersionFailed => error.SolverVersionFailed,
        .SolverFailed => error.SolverFailed,
        .InvalidResponse => error.InvalidSolverResponse,
        .Continue => unreachable,
    };
}
