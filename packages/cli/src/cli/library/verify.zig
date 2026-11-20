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
    index: usize = undefined,
    fn current(self: *const State) *const compiler.library.Export {
        return &self.library.exports[self.index];
    }
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

    const verified = rule.executeIn(scratch.allocator(), @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return if (verified) .success else .failed;
}

pub fn proofExportCount(handle: *const anyopaque) u64 {
    return effects.state(State, handle).library.exports.len;
}

pub fn selectProofExport(handle: *const anyopaque, index: u64) void {
    effects.state(State, handle).index = @intCast(index);
}

pub fn hasExecutableProof(handle: *const anyopaque) bool {
    return effects.state(State, handle).current().function != null;
}

pub fn proofExportName(handle: *const anyopaque) []const u8 {
    return effects.state(State, handle).current().name;
}

pub fn proofOutputBase(handle: *const anyopaque) ?[]const u8 {
    return effects.state(State, handle).context.options.output;
}

pub fn confirmProofInterface(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    self.context.stderr.print("public module {s}: type interface validated; no executable proof obligation\n", .{self.current().name}) catch |err| return self.failure.save(err);
}

pub fn writeProofHeading(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    self.context.stderr.print("public module {s}:\n", .{self.current().name}) catch |err| return self.failure.save(err);
}

pub fn verifyPublicExport(handle: *const anyopaque, output: ?[]const u8) Error!bool {
    const self = effects.state(State, handle);
    const context = self.context;
    const program = self.library.module(self.index) catch |err| return self.failure.save(err);

    return compiler.verification.check(context.io, @import("../verify.zig").workspace_allocator, program, self.sources, self.current().path, .{
        .solver = context.options.solver,
        .output = output,
    }, context.stderr) catch |err| return self.failure.save(err);
}
