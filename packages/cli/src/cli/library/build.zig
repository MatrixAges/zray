const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Compilation = @import("../compilation/state.zig").State;
const Loaded = @import("../project.zig").Loaded;
const Export = @import("../../package/manifest/model.zig").Export;
const analysis = @import("analyze.zig");
const installation = @import("../toolchain.zig");
const Error = @import("../sources/effects.zig").Error;
const rule = @import("cli_source").library_build;
const Inventory = @import("publication_host").inventory;

pub const Build = struct {
    configured: Loaded,
    fallback: [1]Export = undefined,
    analyzed: ?analysis.Result = null,
    library: ?compiler.library.Result = null,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    bundle: ?compiler.zig.LibraryBundle = null,
    native: Loaded = undefined,
    staging: ?[]const u8 = null,
    managed: []const Inventory.File = &.{},
    fn deinit(self: *Build, context: *const Compile.Context) void {
        if (self.staging) |path| std.Io.Dir.cwd().deleteTree(context.io, path) catch {};
        if (self.bundle) |*bundle| bundle.deinit();

        self.sources.deinit(context.allocator);

        if (self.library) |*library| library.deinit();
        if (self.analyzed) |*result| result.deinit();
    }
};

pub fn run(state: *Compilation) !Compile.Status {
    const context = &state.context;
    const reference = state;
    const manifest = std.mem.eql(u8, std.fs.path.basename(context.options.input), "pkg.yaml");

    state.library_build = .{ .configured = state.loaded };

    defer {
        state.library_build.?.deinit(context);

        state.library_build = null;
    }

    const status = rule.executeIn(context.allocator, &.{
        .compilation = @ptrCast(&reference),
        .has_exports = state.loaded.config.exports.len != 0,
        .fallback_entry = if (manifest) state.loaded.config.entry else state.loaded.project.entry,
        .watching = context.watch != null,
    }) catch |err| return state.failure.unwrap(err);

    return switch (status) {
        .Success => .success,
        .Failed => .failed,
        .Retry => .retry,
        .Changed => error.LibraryInputsChanged,
        .MissingEntry => error.MissingLibraryEntry,
    };
}

pub fn analyzeLibraryBuild(handle: *const anyopaque, entry: ?[]const u8) Error!bool {
    const self = Compilation.get(handle);
    const context = &self.context;
    const build = &self.library_build.?;
    const parses = if (context.watch) |attempt| attempt.parse_cache else null;

    if (entry) |path| {
        build.fallback = .{.{ .path = ".", .source = path }};
        build.configured.config.exports = &build.fallback;
    }

    build.analyzed = analysis.run(context.allocator, .{
        .io = context.io,
        .backing = context.backing,
        .loaded = build.configured,
        .writer = context.stderr,
        .inputs = self.inputs().?,
        .parse_cache = parses,
        .preserve_zig_entry = true,
    }) catch |err| return self.failure.save(err);

    return build.analyzed != null;
}

pub fn linkLibraryBuild(handle: *const anyopaque) Error!void {
    const self = Compilation.get(handle);
    const build = &self.library_build.?;

    build.library = build.analyzed.?.link(self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn collectBuildSources(handle: *const anyopaque) Error!void {
    const self = Compilation.get(handle);
    const build = &self.library_build.?;

    build.sources = build.analyzed.?.collectSources(self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn generateLibraryBundle(handle: *const anyopaque) Error!bool {
    const self = Compilation.get(handle);
    const context = &self.context;
    const build = &self.library_build.?;

    const emitted = compiler.emitLibraryVerified(context.allocator, .{
        .io = context.io,
        .sources = build.sources.items,
        .project = self.loaded.project,
        .generation_cache = if (context.options.cache) &self.generation.? else null,
        .solver = context.options.solver,
        .verification_allocator = @import("../verify.zig").workspace_allocator,
        .writer = context.stderr,
    }, &build.library.?) catch |err| return self.failure.save(err);

    switch (emitted) {
        .bundle => |bundle| build.bundle = bundle,
        .diagnostic => |issue| {
            defer issue.deinit();
            context.stderr.print("{s}: {t}: {s}\n", .{ context.options.input, issue.code, issue.message }) catch |err| return self.failure.save(err);

            return false;
        },
    }

    return true;
}

pub fn resolveLibraryToolchain(handle: *const anyopaque) Error!void {
    const self = Compilation.get(handle);
    const context = &self.context;

    self.paths = installation.resolve(context.io, context.allocator, context.environment) catch |err| return self.failure.save(err);
}

pub fn resolveLibraryNativeProject(handle: *const anyopaque) Error!void {
    const self = Compilation.get(handle);
    const build = &self.library_build.?;
    var publication = self.loaded;

    if (build.analyzed.?.legacy_single) publication.config.exports = &.{};

    build.native = @import("../standard.zig").resolve(self.context.allocator, publication, build.bundle.?.native_modules.import_names, self.paths.standard, &.{}) catch |err| return self.failure.save(err);
}

pub fn createLibraryStaging(handle: *const anyopaque) Error!void {
    const self = Compilation.get(handle);
    const context = &self.context;

    var random: [16]u8 = undefined;

    std.Io.random(context.io, &random);

    const name = std.fmt.bytesToHex(random, .lower);
    const path = std.fs.path.resolve(context.allocator, &.{ self.inputs().?.cwd, ".zxc", "build", "library", &name }) catch |err| return self.failure.save(err);

    std.Io.Dir.cwd().createDirPath(context.io, path) catch |err| return self.failure.save(err);

    self.library_build.?.staging = path;
}

pub fn stageLibraryBuild(handle: *const anyopaque) Error!void {
    const self = Compilation.get(handle);
    const context = &self.context;
    const build = &self.library_build.?;

    build.managed = @import("publish.zig").write(.{
        .io = context.io,
        .allocator = context.allocator,
        .backing = context.backing,
        .directory = build.staging.?,
        .library = &build.library.?,
        .bundle = &build.bundle.?,
        .loaded = &build.native,
        .inputs = self.inputs().?,
    }) catch |err| return self.failure.save(err);
}

pub fn publishLibraryBuild(handle: *const anyopaque) Error!bool {
    const self = Compilation.get(handle);
    const context = &self.context;
    const build = &self.library_build.?;

    return @import("../watch/library.zig").publish(context.io, context.backing, build.staging.?, context.options.output.?, build.managed, self.inputs().?) catch |err| return self.failure.save(err);
}
