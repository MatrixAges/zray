const std = @import("std");
const sources = @import("sources.zig");
const rx = @import("rx");
const collection = @import("../rx/collection.zig");
const gateway = @import("../rx/gateway/analyze.zig");
const Compile = @import("../compile.zig");
const project = @import("../project.zig");
const model = @import("../../package/manifest/model.zig");
const configuration = @import("../configuration/root.zig");
const library = @import("../library/analyze.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").lint_semantics;
const abi = @import("cli_abi").layouts.@"zig:lint_workflow_host";
const SemanticProject = abi.SemanticProject;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub const State = struct {
    context: *const Compile.Context,
    loaded: project.Loaded = undefined,
    collection: ?collection.Result = null,
    functions: []const rx.TextSource = &.{},
    gateway: ?gateway.Result = null,
    gateway_view: abi.LintGateway = undefined,
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

    return execute(scoped, &arena) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: semantic lint: {s}\n", .{ context.options.input, @errorName(err) });

        return .failed;
    };
}

fn execute(context: Compile.Context, arena: *std.heap.ArenaAllocator) !Compile.Status {
    var state: State = .{ .context = &context };
    const reference = &state;

    defer {
        if (state.analyzed) |*analyzed| analyzed.deinit();
        if (state.gateway) |*analyzed| analyzed.deinit();
        if (state.collection) |*loaded| loaded.deinit();
    }

    var visited: StoreState = &.{ .paths = &.{} };
    var host: StoreHost = .{ .store_0 = &visited };
    var parsed: ?rx.document.Parsed = null;
    const document = &parsed;

    defer rx.document.release(&parsed);

    const outcome = rule.execute(arena, &.{
        .host = @ptrCast(&reference),
        .document = @ptrCast(&document),
        .maximum_lines = context.options.max_lines,
        .configuration = &.{
            .path = context.options.input,
            .input_path = context.options.input,
            .explicit_kind = configuration.toLayout(context.options.config_kind),
            .linting = context.options.linting,
            .check = context.options.check,
            .write = context.options.write,
        },
    }, &host, context.io) catch |err| return state.failure.unwrap(err);

    if (outcome.failure) |failure| {
        if (failure.error_name) |name| {
            try context.stderr.print("{s}: semantic lint: {s}\n", .{ context.options.input, name });
        } else {
            _ = try @import("source.zig").report(context.stderr, failure.path, failure.result.?);
        }
    }

    if (outcome.configuration) |result| _ = try configuration.report(context, result);

    return switch (outcome.outcome) {
        .Valid => .success,
        .Invalid => .failed,
        .InvalidInput => error.InvalidSemanticInput,
    };
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

pub fn analyzeSemanticLibrary(handle: *const anyopaque, use_entry: bool, entry: ?[]const u8) Error!?[]const *const abi.LintItem {
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

    const analyzed = &(self.analyzed orelse return null);

    return sources.collectItems(context.allocator, analyzed.modules, self.loaded.project.root_dir) catch |err| return self.failure.save(err);
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
