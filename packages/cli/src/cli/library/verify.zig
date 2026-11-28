const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Compilation = @import("../compilation/state.zig").State;
const Error = @import("../sources/effects.zig").Error;
const rule = @import("cli_source").library_public_proof;

pub const Inputs = struct {
    library: *const compiler.library.Result,
    sources: []const compiler.project.Source,
};

pub fn run(state: *Compilation) !Compile.Status {
    const context = &state.context;
    const allocator = context.allocator;
    var analyzed = (try @import("analyze.zig").run(allocator, .{ .io = context.io, .backing = context.backing, .loaded = state.loaded, .writer = context.stderr, .inputs = state.inputs() })) orelse return .failed;

    defer analyzed.deinit();

    var library = try analyzed.link(allocator);

    defer library.deinit();

    var sources = try analyzed.collectSources(allocator);

    defer sources.deinit(allocator);

    const proof: Inputs = .{ .library = &library, .sources = sources.items };
    const reference = state;
    var scratch = std.heap.ArenaAllocator.init(context.backing);

    defer scratch.deinit();

    state.library_proof = &proof;
    defer state.library_proof = null;
    const Input = std.meta.Child(rule.Input);
    const ExportSlot = std.meta.Child(@FieldType(Input, "exports"));
    const ExportItem = if (@typeInfo(ExportSlot) == .pointer) std.meta.Child(ExportSlot) else ExportSlot;
    const scratch_allocator = scratch.allocator();
    const exports = try scratch_allocator.alloc(ExportSlot, library.exports.len);

    for (library.exports, 0..) |item, i| {
        const value: ExportItem = .{ .name = item.name, .executable = item.function != null };

        if (ExportSlot == ExportItem) {
            exports[i] = value;
        } else {
            const slot = try scratch_allocator.create(ExportItem);

            slot.* = value;
            exports[i] = slot;
        }
    }

    const verified = rule.executeIn(scratch_allocator, &.{
        .compilation = @ptrCast(&reference),
        .exports = exports,
        .output_base = context.options.output,
    }) catch |err| return state.failure.unwrap(err);

    return if (verified) .success else .failed;
}

pub fn verifyPublicExport(handle: *const anyopaque, index: u64, output: ?[]const u8) Error!bool {
    const self = Compilation.get(handle);
    const context = &self.context;
    const proof = self.library_proof.?;
    const row: usize = @intCast(index);
    const program = proof.library.module(row) catch |err| return self.failure.save(err);
    const path = proof.library.exports[row].path;

    return compiler.verification.check(context.io, @import("../verify.zig").workspace_allocator, program, proof.sources, path, .{
        .solver = context.options.solver,
        .output = output,
    }, context.stderr) catch |err| return self.failure.save(err);
}
