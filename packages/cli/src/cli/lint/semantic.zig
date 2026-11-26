const std = @import("std");
const Compile = @import("../compile.zig");
const project = @import("../project.zig");
const model = @import("../../package/manifest/model.zig");
const library = @import("../library/analyze.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const SemanticProject = @import("cli_abi").layouts.@"zig:lint_workflow_host".SemanticProject;

const State = struct {
    context: *const Compile.Context,
    loaded: project.Loaded = undefined,
    project_view: SemanticProject = undefined,
    fallback: [1]model.Export = undefined,
    analyzed: ?library.Result = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
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

    defer if (state.analyzed) |*analyzed| analyzed.deinit();

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

    self.project_view = .{
        .entry = if (manifest) self.loaded.config.entry else self.loaded.project.entry,
        .has_exports = self.loaded.config.exports.len != 0,
    };

    return &self.project_view;
}

pub fn clearSemanticLibrary(handle: *const anyopaque) void {
    State.get(handle).loaded.config.library = null;
}

pub fn checkSemanticSpecial(handle: *const anyopaque, manifest: bool, store: bool) Error!bool {
    const self = State.get(handle);
    const selected = if (manifest) self.loaded.config.entry.? else self.loaded.project.entry;
    self.loaded.project.entry = std.fs.path.resolve(self.context.allocator, &.{ self.loaded.project.root_dir, selected }) catch |err| return self.failure.save(err);

    const status = @import("rx.zig").run(self.context.*, &self.loaded, store) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn useSemanticEntryExport(handle: *const anyopaque, manifest: bool) Error!void {
    const self = State.get(handle);
    const selected = if (manifest) self.loaded.config.entry orelse "" else self.loaded.project.entry;

    if (selected.len == 0) return self.failure.save(error.MissingPublicModules);

    self.fallback[0] = .{ .path = ".", .source = selected };
    self.loaded.config.exports = &self.fallback;
}

pub fn analyzeSemanticLibrary(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

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

pub fn linkSemanticLibrary(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    var linked = self.analyzed.?.link(self.context.allocator) catch |err| return self.failure.save(err);

    linked.deinit();
}
