const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const Conditions = @import("conditions.zig");
const Evidence = @import("solver/publication/evidence/output.zig");

const Context = struct {
    hash: *zx.Sha256,
    digest: *[zx.Sha256.digest_length]u8,
    path: *std.Io.Writer,
    output: *std.Io.Writer,
    fn borrow(handle: *const anyopaque) *const @This() {
        return @ptrCast(@alignCast(handle));
    }
};

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
    const settings = @import("generated_verification_proof_constants").@"zx.constants";

    const query = switch (generated.value) {
        .query => |query| query,
        .diagnostic => Conditions.Query{ .feasibility = "", .correctness = "", .inputs = &.{} },
    };

    var hash: zx.Sha256 = undefined;
    var digest: [zx.Sha256.digest_length]u8 = undefined;
    var path_buffer: [settings.proof_path_prefix.len + digest.len * 2 + settings.proof_path_suffix.len]u8 = undefined;
    var path_writer = std.Io.Writer.fixed(&path_buffer);
    const hash_reference: zx.Sha256State = .{ .value = &hash };
    var evidence_bytes: std.Io.Writer.Allocating = .init(allocator);

    defer evidence_bytes.deinit();

    var evidence = Evidence.init(&evidence_bytes);

    const context: Context = .{
        .hash = &hash,
        .digest = &digest,
        .path = &path_writer,
        .output = writer,
    };

    const symbols = zx.memory.borrowTextColumn("symbol", query.inputs);
    const paths = zx.memory.borrowTextColumn("path", query.inputs);

    const input: std.meta.Child(proof.Input) = .{
        .context = @ptrCast(&context),
        .hash = @ptrCast(&hash_reference),
        .path_writer = @ptrCast(&path_writer),
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

    return switch (try proof.executeIn(allocator, &input, io)) {
        .Proved => true,
        .Unsupported, .Counterexample, .Infeasible, .Unknown => false,
        .VersionFailed => error.SolverVersionFailed,
        .SolverFailed => error.SolverFailed,
        .InvalidResponse => error.InvalidSolverResponse,
        .Continue => unreachable,
    };
}

pub fn finishVerificationDigest(handle: *const anyopaque) []const u8 {
    const context = Context.borrow(handle);

    context.hash.final(context.digest);

    return context.digest;
}

pub fn verificationPathText(handle: *const anyopaque) []const u8 {
    return Context.borrow(handle).path.buffered();
}

pub fn writeVerificationOutput(handle: *const anyopaque, content: []const u8) std.Io.Writer.Error!void {
    return Context.borrow(handle).output.writeAll(content);
}
