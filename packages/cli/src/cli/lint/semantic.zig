const std = @import("std");
const rx = @import("rx");
const collection = @import("../rx/collection.zig");
const gateway = @import("../rx/gateway/analyze.zig");
const Compile = @import("../compile.zig");
const project = @import("../project.zig");
const model = @import("../../package/manifest/model.zig");
const library = @import("../library/analyze.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const SemanticProject = @import("cli_abi").layouts.@"zig:lint_workflow_host".SemanticProject;

pub const State = struct {
    context: *const Compile.Context,
    loaded: project.Loaded = undefined,
    collection: ?collection.Result = null,
    functions: []const rx.TextSource = &.{},
    gateway: ?gateway.Result = null,
    project_view: SemanticProject = undefined,
    fallback: [1]model.Export = undefined,
    analyzed: ?library.Result = null,
    failure: effects.Failure = .{},
    pub fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
};

pub fn run(context: Compile.Context) !Compile.Status {
    var arena = std.heap.ArenaAllocator.init(context.allocator);

    defer arena.deinit();

    var scoped = context;

    scoped.allocator = arena.allocator();

    return execute(scoped) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: semantic lint: {s}\n", .{ context.options.input, @errorName(err) });

        return .failed;
    };
}

fn execute(context: Compile.Context) !Compile.Status {
    var state: State = .{ .context = &context };
    const reference = &state;

    defer {
        if (state.analyzed) |*analyzed| analyzed.deinit();
        if (state.gateway) |*analyzed| analyzed.deinit();
        if (state.collection) |*loaded| loaded.deinit();
    }

    const outcome = @import("cli_source").lint_semantics.executeIn(context.allocator, &.{
        .host = @ptrCast(&reference),
        .input_path = context.options.input,
    }) catch |err| return state.failure.unwrap(err);

    return switch (outcome) {
        .Valid => .success,
        .Invalid => .failed,
        .InvalidInput => error.InvalidSemanticInput,
    };
}

pub fn checkSemanticManifest(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const status = @import("../configuration/root.zig").run(self.context.*) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn loadSemanticProject(handle: *const anyopaque, manifest: bool) Error!?*const SemanticProject {
    const self = State.get(handle);
    const context = self.context;

    self.loaded = project.load(context.io, context.allocator, context.options.input, context.options.project) catch |err| return self.failure.save(err);

    if (self.loaded.diagnostic) |message| {
        context.stderr.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return null;
    }

    if (!manifest) self.loaded.config.library = null;

    self.project_view = .{
        .entry = if (manifest) self.loaded.config.entry else self.loaded.project.entry,
        .has_exports = self.loaded.config.exports.len != 0,
    };

    return &self.project_view;
}

pub fn prepareSemanticSpecial(handle: *const anyopaque, entry: ?[]const u8) Error!void {
    const self = State.get(handle);
    self.loaded.project.entry = std.fs.path.resolve(self.context.allocator, &.{ self.loaded.project.root_dir, entry.? }) catch |err| return self.failure.save(err);
}

pub fn analyzeSemanticLibrary(handle: *const anyopaque, use_entry: bool, entry: ?[]const u8) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    if (use_entry) {
        const selected = entry orelse return self.failure.save(error.MissingPublicModules);

        if (selected.len == 0) return self.failure.save(error.MissingPublicModules);

        self.fallback[0] = .{ .path = ".", .source = selected };
        self.loaded.config.exports = &self.fallback;
    }

    self.analyzed = library.run(context.allocator, .{
        .io = context.io,
        .backing = context.backing,
        .loaded = self.loaded,
        .writer = context.stderr,
    }) catch |err| return self.failure.save(err);

    return self.analyzed != null;
}

pub fn checkSemanticSources(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const status = @import("sources.zig").check(self.context.*, self.analyzed.?.modules, self.loaded.project.root_dir) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn linkSemanticLibrary(handle: *const anyopaque, is_gateway: bool) Error!void {
    const self = State.get(handle);
    const allocator = self.context.allocator;

    var linked: ?@import("compiler").library.Result = if (is_gateway)
        self.gateway.?.link(allocator) catch |err| return self.failure.save(err)

    else
        self.analyzed.?.link(allocator) catch |err| return self.failure.save(err);

    if (linked) |*result| result.deinit();
}
