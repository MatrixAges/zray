const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const Conditions = @import("conditions.zig");
const Evidence = @import("solver/publication/evidence/output.zig");

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

    var evidence_bytes: std.Io.Writer.Allocating = .init(allocator);

    defer evidence_bytes.deinit();

    var evidence = Evidence.init(&evidence_bytes);
    const symbols = zx.memory.borrowTextColumn("symbol", query.inputs);
    const paths = zx.memory.borrowTextColumn("path", query.inputs);

    const input: std.meta.Child(proof.Input) = .{
        .diagnostic = if (generated.value == .diagnostic) generated.value.diagnostic.message else null,
        .output = options.output,
        .solver = options.solver,
        .feasibility = query.feasibility,
        .correctness = query.correctness,
        .bindings = &.{ .symbols = @ptrCast(&symbols), .paths = @ptrCast(&paths), .count = query.inputs.len },
        .evidence = &.{
            .writer = @ptrCast(&evidence),
            .sources = @ptrCast(&sources),
            .entry = entry,
            .version = program.version,
            .types = @ptrCast(&program.types),
            .inputs = @ptrCast(&query.inputs),
            .program = @ptrCast(&program),
        },
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
