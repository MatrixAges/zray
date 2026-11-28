const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const Conditions = @import("conditions.zig");
const Evidence = @import("solver/publication/evidence/output.zig");
pub const writeEvidence = Evidence.write;

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

    const evidence_sources = if (generated.value == .query)
        try zx.columns.bridge(@FieldType(EvidenceInput, "sources"), allocator, sources)
    else
        &.{};

    const evidence_inputs = try bindingRows(@FieldType(EvidenceInput, "inputs"), allocator, query.inputs);

    const input: Request = .{
        .diagnostic = if (generated.value == .diagnostic) generated.value.diagnostic.message else null,
        .output = options.output,
        .solver = options.solver,
        .feasibility = query.feasibility,
        .correctness = query.correctness,
        .bindings = &.{ .symbols = @ptrCast(&symbols), .paths = @ptrCast(&paths), .count = query.inputs.len },
        .evidence = &.{
            .sources = evidence_sources,
            .entry = entry,
            .version = program.version,
            .inputs = evidence_inputs,
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

fn bindingRows(comptime Rows: type, allocator: std.mem.Allocator, inputs: []const Conditions.Input) std.mem.Allocator.Error!Rows {
    const Row = std.meta.Child(std.meta.Elem(Rows));
    const values = try allocator.alloc(Row, inputs.len);
    const pointers = try allocator.alloc(*const Row, inputs.len);

    for (inputs, values, pointers) |input, *row, *pointer| {
        row.* = .{
            .symbol = input.symbol,
            .path = input.path,
            .type_id = @backingInt(input.type_id),
        };

        pointer.* = row;
    }

    return pointers;
}
