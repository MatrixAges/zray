const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Loaded = @import("../project.zig").Loaded;
const Inputs = @import("watch_inputs").Inputs;
const effects = @import("workflow/effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").library_public_proof;

const State = struct {
    context: *const Compile.Context,
    library: *const compiler.library.Result,
    sources: []const compiler.project.Source,
    failure: effects.Failure = .{},
};

pub fn run(context: Compile.Context, loaded: Loaded, inputs: ?*Inputs) !Compile.Status {
    const allocator = context.allocator;
    var analyzed = (try @import("analyze.zig").run(allocator, .{ .io = context.io, .backing = context.backing, .loaded = loaded, .writer = context.stderr, .inputs = inputs })) orelse return .failed;

    defer analyzed.deinit();

    var library = try analyzed.link(allocator);

    defer library.deinit();

    var sources = try analyzed.collectSources(allocator);

    defer sources.deinit(allocator);

    var state: State = .{ .context = &context, .library = &library, .sources = sources.items };
    const reference = &state;
    var scratch = std.heap.ArenaAllocator.init(context.backing);

    defer scratch.deinit();

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
        .proof = @ptrCast(&reference),
        .exports = exports,
        .output_base = context.options.output,
    }) catch |err| return state.failure.unwrap(err);

    return if (verified) .success else .failed;
}

pub fn writeProofMessage(handle: *const anyopaque, message: []const u8) Error!void {
    const self = effects.state(State, handle);

    self.context.stderr.writeAll(message) catch |err| return self.failure.save(err);
}

pub fn verifyPublicExport(handle: *const anyopaque, index: u64, output: ?[]const u8) Error!bool {
    const self = effects.state(State, handle);
    const context = self.context;
    const row: usize = @intCast(index);
    const program = self.library.module(row) catch |err| return self.failure.save(err);
    const path = self.library.exports[row].path;

    return compiler.verification.check(context.io, @import("../verify.zig").workspace_allocator, program, self.sources, path, .{
        .solver = context.options.solver,
        .output = output,
    }, context.stderr) catch |err| return self.failure.save(err);
}
