const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Loaded = @import("../project.zig").Loaded;
const Inputs = @import("watch_inputs").Inputs;
const Export = @import("../../package/manifest/model.zig").Export;
const analysis = @import("analyze.zig");
const generation = @import("../generation_cache.zig");
const installation = @import("../toolchain.zig");
const effects = @import("workflow/effects.zig");
const Error = effects.Error;
const Status = @import("library_workflow_abi").native.@"zig:library_workflow_host".BuildStatus;
const rule = @import("cli_source").library_build;
const Inventory = @import("publication_host").inventory;

const State = struct {
    context: *const Compile.Context,
    loaded: *const Loaded,
    inputs: *Inputs,
    configured: Loaded,
    fallback: [1]Export = undefined,
    failure: effects.Failure = .{},
    analyzed: ?analysis.Result = null,
    library: ?compiler.library.Result = null,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    cache: ?compiler.zig.GenerationCache = null,
    bundle: ?compiler.zig.LibraryBundle = null,
    toolchain: installation.Paths = undefined,
    native: Loaded = undefined,
    staging: ?[]const u8 = null,
    managed: []const Inventory.File = &.{},
    fn deinit(self: *State) void {
        const context = self.context;

        if (self.staging) |path| std.Io.Dir.cwd().deleteTree(context.io, path) catch {};
        if (self.bundle) |*bundle| bundle.deinit();
        if (self.cache) |*cache| cache.deinit();

        self.sources.deinit(context.allocator);

        if (self.library) |*library| library.deinit();
        if (self.analyzed) |*result| result.deinit();
    }
};

pub fn run(context: Compile.Context, loaded: Loaded, inputs: *Inputs) !Compile.Status {
    var state: State = .{ .context = &context, .loaded = &loaded, .inputs = inputs, .configured = loaded };
    const reference = &state;

    defer state.deinit();

    const status = rule.executeIn(context.allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return switch (status) {
        .Success => .success,
        .Failed => .failed,
        .Retry => .retry,
    };
}

pub fn hasBuildExports(handle: *const anyopaque) bool {
    return effects.state(State, handle).configured.config.exports.len != 0;
}

pub fn configureLibraryEntry(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const loaded = self.loaded;
    const manifest = std.mem.eql(u8, std.fs.path.basename(self.context.options.input), "pkg.yaml");
    const source = if (manifest) loaded.config.entry orelse return self.failure.save(error.MissingLibraryEntry) else loaded.project.entry;

    self.fallback = .{.{ .path = ".", .source = source }};
    self.configured.config.exports = &self.fallback;
}

pub fn analyzeLibraryBuild(handle: *const anyopaque) Error!bool {
    const self = effects.state(State, handle);
    const context = self.context;
    const parses = if (context.watch) |attempt| attempt.parse_cache else null;

    self.analyzed = analysis.run(context.allocator, .{
        .io = context.io,
        .backing = context.backing,
        .loaded = self.configured,
        .writer = context.stderr,
        .inputs = self.inputs,
        .parse_cache = parses,
        .preserve_zig_entry = true,
    }) catch |err| return self.failure.save(err);

    return self.analyzed != null;
}

pub fn linkLibraryBuild(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    self.library = self.analyzed.?.link(self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn collectBuildSources(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    self.sources = self.analyzed.?.collectSources(self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn openLibraryBuildCache(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const context = self.context;

    self.cache = generation.init(context.io, context.allocator, self.loaded.project.root_dir) catch |err| return self.failure.save(err);
}

pub fn generateLibraryBundle(handle: *const anyopaque) Error!bool {
    const self = effects.state(State, handle);
    const context = self.context;

    const emitted = compiler.emitLibraryVerified(context.allocator, .{
        .io = context.io,
        .sources = self.sources.items,
        .project = self.loaded.project,
        .generation_cache = if (context.options.cache) &self.cache.? else null,
        .solver = context.options.solver,
        .verification_allocator = @import("../verify.zig").workspace_allocator,
        .writer = context.stderr,
    }, &self.library.?) catch |err| return self.failure.save(err);

    switch (emitted) {
        .bundle => |bundle| self.bundle = bundle,
        .diagnostic => |issue| {
            defer issue.deinit();
            context.stderr.print("{s}: {t}: {s}\n", .{ context.options.input, issue.code, issue.message }) catch |err| return self.failure.save(err);

            return false;
        },
    }

    return true;
}

pub fn reportLibraryBuildCache(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const context = self.context;

    generation.report(&self.cache.?, context.options, context.stderr) catch |err| return self.failure.save(err);
}

pub fn resolveLibraryToolchain(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const context = self.context;

    self.toolchain = installation.resolve(context.io, context.allocator, context.environment) catch |err| return self.failure.save(err);
}

pub fn resolveLibraryNativeProject(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    var publication = self.loaded.*;

    if (self.analyzed.?.legacy_single) publication.config.exports = &.{};

    self.native = @import("../standard.zig").resolve(self.context.allocator, publication, self.bundle.?.native_modules.import_names, self.toolchain.standard, &.{}) catch |err| return self.failure.save(err);
}

pub fn createLibraryStaging(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const context = self.context;
    var random: [16]u8 = undefined;

    std.Io.random(context.io, &random);

    const name = std.fmt.bytesToHex(random, .lower);
    const path = std.fs.path.resolve(context.allocator, &.{ self.inputs.cwd, ".zxc", "build", "library", &name }) catch |err| return self.failure.save(err);

    std.Io.Dir.cwd().createDirPath(context.io, path) catch |err| return self.failure.save(err);

    self.staging = path;
}

pub fn stageLibraryBuild(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const context = self.context;

    self.managed = @import("publish.zig").write(.{
        .io = context.io,
        .allocator = context.allocator,
        .backing = context.backing,
        .directory = self.staging.?,
        .library = &self.library.?,
        .bundle = &self.bundle.?,
        .loaded = &self.native,
        .inputs = self.inputs,
    }) catch |err| return self.failure.save(err);
}

pub fn publishLibraryBuild(handle: *const anyopaque) Error!bool {
    const self = effects.state(State, handle);
    const context = self.context;

    return @import("../watch/library.zig").publish(context.io, context.backing, self.staging.?, context.options.output.?, self.managed, self.inputs) catch |err| return self.failure.save(err);
}

pub fn libraryBuildWatching(handle: *const anyopaque) bool {
    return effects.state(State, handle).context.watch != null;
}

pub fn rejectChangedLibraryBuild(handle: *const anyopaque) Error!void {
    return effects.state(State, handle).failure.save(error.LibraryInputsChanged);
}
