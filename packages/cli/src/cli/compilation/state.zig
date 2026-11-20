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
const native = @import("../build/native.zig");
const toolchain = @import("../toolchain.zig");

pub const State = struct {
    context: Compile.Context,
    library_inputs: ?Inputs = null,
    loaded: Loaded = undefined,
    source: ?[]const u8 = null,
    semantic: ?compiler.project.SemanticCache = null,
    storage: ?Disk = null,
    libraries: ?Libraries = null,
    swapped: bool = false,
    has_rx_import: bool = false,
    sources: []const compiler.project.Source = &.{},
    analyzed: ?compiler.AnalysisResult = null,
    generation: ?compiler.zig.GenerationCache = null,
    abi: std.Io.Writer.Allocating,
    text: ?[]u8 = null,
    bundle: ?compiler.zig.ModuleBundle = null,
    paths: toolchain.Paths = undefined,
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
    const reference = &state;

    defer state.deinit();

    const result = @import("cli_source").compile_command.executeIn(context.allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return native.status(result);
}

pub fn compilationLinting(handle: *const anyopaque) bool {
    return State.get(handle).options().linting;
}

pub fn runCompilationLint(handle: *const anyopaque) Error!native.Status {
    const self = State.get(handle);
    const result = @import("../lint.zig").run(self.context) catch |err| return self.failure.save(err);

    return native.sourceStatus(result);
}

pub fn compilationFormatting(handle: *const anyopaque) bool {
    return State.get(handle).options().formatting;
}

pub fn compilationIsConfiguration(handle: *const anyopaque) bool {
    const options = State.get(handle).options();

    return options.config_kind != null or std.mem.endsWith(u8, options.input, ".yaml") or std.mem.endsWith(u8, options.input, ".json");
}

pub fn runCompilationConfiguration(handle: *const anyopaque) Error!native.Status {
    const self = State.get(handle);
    const result = @import("../configuration/root.zig").run(self.context) catch |err| return self.failure.save(err);

    return native.sourceStatus(result);
}

pub fn compilationIsLibrary(handle: *const anyopaque) bool {
    return State.get(handle).options().mode == .lib;
}

pub fn compilationWatching(handle: *const anyopaque) bool {
    return State.get(handle).context.watch != null;
}

pub fn openCompilationInputs(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.library_inputs = Inputs.init(self.context.io, self.context.allocator) catch |err| return self.failure.save(err);
}

pub fn resolveCompilationEntry(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = &self.context;
    const observed = self.inputs();
    const path = @import("../sources/module_path.zig").entry(context.io, context.allocator, context.options.input, observed) catch |err| return self.failure.save(err);

    context.options.input = path;

    if (observed) |inputs| inputs.add(context.io, path) catch |err| return self.failure.save(err);
}

pub fn compilationIsRx(handle: *const anyopaque) bool {
    return std.mem.endsWith(u8, State.get(handle).options().input, ".rx");
}

pub fn runCompilationRx(handle: *const anyopaque) Error!native.Status {
    const self = State.get(handle);
    const result = @import("../rx/compile.zig").run(self.context) catch |err| return self.failure.save(err);

    return native.sourceStatus(result);
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

pub fn compilationIsManifest(handle: *const anyopaque) bool {
    return std.mem.eql(u8, std.fs.path.basename(State.get(handle).options().input), "pkg.yaml");
}

pub fn compilationVerifying(handle: *const anyopaque) bool {
    return State.get(handle).options().verifying;
}

pub fn compilationNative(handle: *const anyopaque) bool {
    return State.get(handle).options().native;
}

pub fn runCompilationLibraryProof(handle: *const anyopaque) Error!native.Status {
    const self = State.get(handle);
    const context = &self.context;

    const result = @import("../library/verify.zig").run(context.*, self.loaded, self.inputs()) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.failure.save(err);

        context.stderr.print("{s}: public module verification: {s}\n", .{ context.options.input, @errorName(err) }) catch |issue| return self.failure.save(issue);
        context.stderr.flush() catch |issue| return self.failure.save(issue);

        return .Failed;
    };

    return native.sourceStatus(result);
}

pub fn runCompilationLibraryBuild(handle: *const anyopaque) Error!native.Status {
    const self = State.get(handle);
    const context = &self.context;

    const result = @import("../library/build.zig").run(context.*, self.loaded, self.inputs().?) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.failure.save(err);

        context.stderr.print("{s}: library build: {s}\n", .{ context.options.input, @errorName(err) }) catch |issue| return self.failure.save(issue);
        context.stderr.flush() catch |issue| return self.failure.save(issue);

        return .Failed;
    };

    return native.sourceStatus(result);
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

pub fn readCompilationDependencies(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = &self.context;

    const detected = sources.readDetectingRx(context.io, context.allocator, self.source.?, self.loaded.project, self.watchingParses() orelse &self.semantic.?.parse_cache, self.inputs(), &self.libraries.?) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        context.stderr.print("{s}: source loading: {s}\n", .{ self.libraries.?.failure_path orelse context.options.input, @errorName(err) }) catch |issue| return self.failure.save(issue);
        context.stderr.flush() catch |issue| return self.failure.save(issue);

        return false;
    };

    self.sources = detected.sources;
    self.has_rx_import = detected.has_rx;

    return true;
}

pub fn compilationHasRxImport(handle: *const anyopaque) bool {
    return State.get(handle).has_rx_import;
}

pub fn adoptCompilationInputs(handle: *const anyopaque) void {
    const self = State.get(handle);

    if (self.watchingParses()) |parsed| {
        std.mem.swap(compiler.project.ParseCache, parsed, &self.semantic.?.parse_cache);

        self.swapped = true;
    }

    self.loaded.project.compiled_libraries = self.libraries.?.libraries.items;
}
