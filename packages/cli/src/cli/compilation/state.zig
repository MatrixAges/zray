const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const Loaded = @import("../project.zig").Loaded;
const Inputs = @import("watch_inputs").Inputs;
const Effects = @import("../sources/effects.zig");
const Error = Effects.Error;
const Disk = @import("../cache.zig");
const Libraries = @import("../library/inputs.zig");
const sources = @import("../sources.zig");
const toolchain = @import("../toolchain.zig");
const library_build = @import("../library/build.zig");
const library_proof = @import("../library/verify.zig");
const Dependencies = @import("cli_abi").native.@"zig:compilation_host".Dependencies;

pub const State = struct {
    context: Compile.Context,
    library_inputs: ?Inputs = null,
    loaded: Loaded = undefined,
    source: ?[]const u8 = null,
    semantic: ?compiler.project.SemanticCache = null,
    storage: ?Disk = null,
    libraries: ?Libraries = null,
    swapped: bool = false,
    sources: []const compiler.project.Source = &.{},
    analyzed: ?compiler.AnalysisResult = null,
    generation: ?compiler.zig.GenerationCache = null,
    abi: std.Io.Writer.Allocating,
    text: ?[]u8 = null,
    text_view: @import("cli_abi").layouts.@"zig:compilation_host".CompilationText = undefined,
    bundle: ?compiler.zig.ModuleBundle = null,
    paths: toolchain.Paths = undefined,
    library_build: ?library_build.Build = null,
    library_proof: ?*const library_proof.Inputs = null,
    failure: Effects.Failure = .{},
    pub fn get(handle: *const anyopaque) *State {
        return Effects.state(State, handle);
    }

    pub fn options(self: *const State) *const @import("../options.zig").Options {
        return &self.context.options;
    }

    pub fn inputs(self: *State) ?*Inputs {
        if (self.context.watch) |attempt| return attempt.inputs;
        if (self.library_inputs) |*observed| return observed;

        return null;
    }

    pub fn watchingParses(self: *const State) ?*compiler.project.ParseCache {
        return if (self.context.watch) |attempt| attempt.parse_cache else null;
    }
    fn deinit(self: *State) void {
        const allocator = self.context.allocator;

        if (self.text) |text| allocator.free(text);
        if (self.generation) |*cache| cache.deinit();
        if (self.bundle) |*bundle| bundle.deinit();

        self.abi.deinit();

        if (self.analyzed) |*analyzed| analyzed.deinit();
        if (self.swapped) std.mem.swap(compiler.project.ParseCache, self.watchingParses().?, &self.semantic.?.parse_cache);
        if (self.libraries) |*libraries| libraries.deinit();
        if (self.storage) |*storage| storage.deinit();
        if (self.semantic) |*semantic| semantic.deinit();
        if (self.source) |source| allocator.free(source);
        if (self.library_inputs) |*observed| observed.deinit();
    }
};

pub fn run(context: Compile.Context) !Compile.Status {
    var state: State = .{ .context = context, .abi = .init(context.allocator) };
    const entry = @import("cli_source").compile_command;
    const settings = context.options.executionSettings();
    const reference = &state;

    const request: std.meta.Child(entry.Input) = .{
        .compilation = @ptrCast(&reference),
        .settings = &settings,
        .watching = context.watch != null,
        .input = context.options.input,
        .explicit_config = context.options.config_kind != null,
        .formatting_notice = @import("lint").source.formatting_required,
    };

    defer state.deinit();

    const result = entry.executeIn(context.allocator, &request, context.io) catch |err| return state.failure.unwrap(err);

    if (result.diagnostic) |message| {
        try context.stderr.writeAll(message);
        try context.stderr.flush();
    }

    if (result.stdout) |source| try context.stdout.writeAll(source);

    return switch (result.status) {
        .Success => .success,
        .Failed => .failed,
        .BackendFailed => .backend_failed,
        .Retry => .retry,
        .Linting => @import("../lint.zig").run(state.context),
        .Configuration => @import("../configuration/root.zig").run(state.context),
        .RunRx => @import("../rx/compile.zig").run(state.context),
        .LibraryProof => runLibraryProof(&state),
        .LibraryBuild => runLibraryBuild(&state),
    };
}

pub fn resolveCompilationEntry(handle: *const anyopaque, track_library: bool) Error![]const u8 {
    const self = State.get(handle);
    const context = &self.context;

    if (track_library) {
        self.library_inputs = Inputs.init(context.io, context.allocator) catch |err| return self.failure.save(err);
    }

    const observed = self.inputs();
    const path = @import("../sources/module_path.zig").entry(context.io, context.allocator, context.options.input, observed) catch |err| return self.failure.save(err);

    context.options.input = path;

    if (observed) |inputs| inputs.add(context.io, path) catch |err| return self.failure.save(err);

    return path;
}

pub fn loadCompilationProject(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = &self.context;
    const options = &context.options;
    const writer = context.stderr;

    self.loaded = @import("../project.zig").loadWithInputs(context.io, context.allocator, options.input, options.project, self.inputs()) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.failure.save(err);

        writer.print("{s}: {s}\n", .{ options.project orelse "pkg.yaml", @errorName(err) }) catch |issue| return self.failure.save(issue);
        writer.flush() catch |issue| return self.failure.save(issue);

        return false;
    };

    if (self.loaded.diagnostic) |message| {
        writer.print("{s}\n", .{message}) catch |err| return self.failure.save(err);
        writer.flush() catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

fn runLibraryProof(self: *State) !Compile.Status {
    const context = &self.context;

    const result = library_proof.run(self) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: public module verification: {s}\n", .{ context.options.input, @errorName(err) });
        try context.stderr.flush();

        return .failed;
    };

    return result;
}

fn runLibraryBuild(self: *State) !Compile.Status {
    const context = &self.context;

    const result = library_build.run(self) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: library build: {s}\n", .{ context.options.input, @errorName(err) });
        try context.stderr.flush();

        return .failed;
    };

    return result;
}

pub fn readCompilationSource(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = &self.context;
    const path = context.options.input;

    self.source = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        context.stderr.print("{s}: {s}\n", .{ path, @errorName(err) }) catch |issue| return self.failure.save(issue);

        return false;
    };

    return true;
}

pub fn openCompilationCaches(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = &self.context;

    self.semantic = compiler.project.SemanticCache.init(context.backing);
    self.storage = Disk.init(context.io, context.allocator, context.backing, self.loaded.project.root_dir) catch |err| return self.failure.save(err);
    self.libraries = .{ .allocator = context.allocator };
}

pub fn readCompilationDependencies(handle: *const anyopaque) Error!Dependencies {
    const self = State.get(handle);
    const context = &self.context;

    const detected = sources.readDetectingRx(context.io, context.allocator, self.source.?, self.loaded.project, self.watchingParses() orelse &self.semantic.?.parse_cache, self.inputs(), &self.libraries.?) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        context.stderr.print("{s}: source loading: {s}\n", .{ self.libraries.?.failure_path orelse context.options.input, @errorName(err) }) catch |issue| return self.failure.save(issue);
        context.stderr.flush() catch |issue| return self.failure.save(issue);

        return .Invalid;
    };

    self.sources = detected.sources;

    if (detected.has_rx) return .Rx;

    if (self.watchingParses()) |parsed| {
        std.mem.swap(compiler.project.ParseCache, parsed, &self.semantic.?.parse_cache);

        self.swapped = true;
    }

    self.loaded.project.compiled_libraries = self.libraries.?.libraries.items;

    return if (self.loaded.project.compiled_libraries.len == 0) .Zx else .WithLibraries;
}
