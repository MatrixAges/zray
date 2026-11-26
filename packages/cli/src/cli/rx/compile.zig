const std = @import("std");
const compiler = @import("compiler");
const Compile = @import("../compile.zig");
const project = @import("../project.zig");
const analyze = @import("analyze.zig");
const cache = @import("../generation_cache.zig");
const toolchain = @import("../toolchain.zig");
const native = @import("../build/native.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    context: *const Compile.Context,
    loaded: project.Loaded = undefined,
    parsing: ?compiler.project.ParseCache = null,
    prepared: ?analyze.Result = null,
    cache: ?compiler.zig.GenerationCache = null,
    type_output: std.Io.Writer.Allocating,
    text: ?[]u8 = null,
    bundle: ?compiler.zig.ModuleBundle = null,
    store_memory: ?std.heap.ArenaAllocator = null,
    initializers: []const compiler.zig.store_initializers.Initializer.Borrowed = &.{},
    paths: toolchain.Paths = undefined,
    native_project: project.Loaded = undefined,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn closeStore(self: *State) void {
        if (self.store_memory) |*scratch| scratch.deinit();

        self.store_memory = null;
        self.initializers = &.{};
    }

    fn deinit(self: *State) void {
        self.closeStore();

        if (self.bundle) |*bundle| bundle.deinit();
        if (self.text) |text| self.context.allocator.free(text);

        self.type_output.deinit();

        if (self.cache) |*generation| generation.deinit();
        if (self.prepared) |*prepared| prepared.analysis.deinit();
        if (self.parsing) |*parsing| parsing.deinit();
    }
    fn reportFailure(self: *State, err: anyerror) Error!bool {
        if (err == error.OutOfMemory or err == error.Canceled) return self.failure.save(err);

        self.context.stderr.print("{s}: {s}\n", .{ self.context.options.input, @errorName(err) }) catch |issue| return self.failure.save(issue);

        return false;
    }

    fn inputs(self: *const State) ?*@import("watch_inputs").Inputs {
        return if (self.context.watch) |attempt| attempt.inputs else null;
    }

    fn generationCache(self: *State) ?*compiler.zig.GenerationCache {
        const options = &self.context.options;

        return if (options.native and options.cache) &self.cache.? else null;
    }

    fn configuration(self: *State) compiler.CompileOptions {
        const context = self.context;
        const options = &context.options;

        return .{
            .io = context.io,
            .concurrent_analysis = context.concurrent_analysis,
            .sources = self.prepared.?.sources,
            .project = self.loaded.project,
            .generation_cache = self.generationCache(),
            .solver = options.solver,
            .verification_allocator = @import("../verify.zig").workspace_allocator,
            .writer = context.stderr,
            .type_output = if (options.output != null) &self.type_output.writer else null,
        };
    }
    fn reportDiagnostic(self: *State, issue: compiler.Diagnostic) Error!bool {
        defer issue.deinit();
        self.context.stderr.print("{s}: {t}: {s}\n", .{ self.context.options.input, issue.code, issue.message }) catch |err| return self.failure.save(err);

        return false;
    }
};

pub fn run(context: Compile.Context) !Compile.Status {
    var state: State = .{ .context = &context, .type_output = .init(context.allocator) };
    const entry = @import("cli_source").run_rx_application;
    const settings = context.options.executionSettings();
    const reference = &state;

    const request: std.meta.Child(entry.Input) = .{
        .application = @ptrCast(&reference),
        .settings = &settings,
    };

    defer state.deinit();

    const result = entry.executeIn(context.allocator, &request) catch |err| return state.failure.unwrap(err);

    return native.status(result);
}

pub fn reportRxLibraryEntry(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll("RX libraries require the unified package publishing entry\n") catch |err| return self.failure.save(err);
}

pub fn loadRxApplication(handle: *const anyopaque) Error!?[]const u8 {
    const self = State.get(handle);
    const context = self.context;

    self.loaded = project.loadWithInputs(context.io, context.allocator, context.options.input, context.options.project, self.inputs()) catch |err| {
        _ = try self.reportFailure(err);

        return null;
    };

    if (self.loaded.diagnostic) |message| {
        context.stderr.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return null;
    }

    return self.loaded.project.entry;
}

pub fn buildRxGateway(handle: *const anyopaque) Error!native.RxStatus {
    const self = State.get(handle);

    const result = @import("gateway/compile.zig").run(self.context, &self.loaded) catch |err| {
        _ = try self.reportFailure(err);

        return .Failed;
    };

    return native.sourceStatusAs(native.RxStatus, result);
}

pub fn analyzeRxApplication(handle: *const anyopaque) Error!?u64 {
    const self = State.get(handle);
    const context = self.context;
    const watched = if (context.watch) |attempt| attempt.parse_cache else null;
    self.parsing = .{ .allocator = context.backing, .keeps_replaced = true };

    self.prepared = analyze.run(context.allocator, .{
        .io = context.io,
        .project = self.loaded.project,
        .writer = context.stderr,
        .parse_cache = watched orelse &self.parsing.?,
        .inputs = self.inputs(),
    }) catch |err| {
        _ = try self.reportFailure(err);

        return null;
    };

    return if (self.prepared) |*prepared| prepared.analysis.value.ir.stores.count() else null;
}

pub fn verifyRxApplication(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const prepared = &self.prepared.?;

    return compiler.verification.check(context.io, @import("../verify.zig").workspace_allocator, prepared.analysis.value.ir, prepared.sources, self.loaded.project.entry, .{
        .solver = context.options.solver,
        .output = context.options.output,
    }, context.stderr) catch |err| return self.reportFailure(err);
}

pub fn generateRxFpga(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const prepared = &self.prepared.?;

    return @import("../fpga.zig").runProgram(self.context.*, &prepared.analysis.value.ir, prepared.sources, self.loaded.project.entry) catch |err| return self.reportFailure(err);
}

pub fn openRxApplicationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.cache = cache.init(context.io, context.allocator, self.loaded.project.root_dir) catch |err| return self.failure.save(err);
}

pub fn emitRxApplicationText(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const result = compiler.emitProgramVerified(self.context.allocator, self.configuration(), &self.prepared.?.analysis) catch |err| return self.failure.save(err);

    if (result == .diagnostic) return self.reportDiagnostic(result.diagnostic);

    self.text = result.source;

    return true;
}

pub fn writeRxApplicationText(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const path = context.options.output.?;
    const artifacts = @import("../artifacts.zig");

    if (self.type_output.written().len != 0) {
        const abi_path = std.fmt.allocPrint(context.allocator, "{s}.abi.zig", .{path}) catch |err| return self.failure.save(err);

        artifacts.write(context.io, abi_path, self.type_output.written()) catch |err| return self.failure.save(err);
    }

    artifacts.write(context.io, path, self.text.?) catch |err| return self.failure.save(err);
}

pub fn printRxApplicationText(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stdout.writeAll(self.text.?) catch |err| return self.failure.save(err);
}

pub fn emitRxApplicationModules(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const result = compiler.emitModulesVerified(self.context.allocator, self.configuration(), &self.prepared.?.analysis) catch |err| return self.failure.save(err);

    if (result == .diagnostic) return self.reportDiagnostic(result.diagnostic);

    self.bundle = result.bundle;

    return true;
}

pub fn collectRxInitializers(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const prepared = &self.prepared.?;

    self.store_memory = .init(self.bundle.?.arena.child_allocator);
    self.initializers = @import("rx_analysis").store.collectInitializers(self.store_memory.?.allocator(), prepared.store_definitions, &prepared.analysis.value.ir, &.{}) catch |err| return self.failure.save(err);
}

pub fn emitRxInitializers(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    compiler.zig.store_initializers.append(&self.bundle.?, .{
        .analysis = &self.prepared.?.analysis,
        .borrowed_initializers = self.initializers,
        .cache = self.generationCache(),
    }) catch |err| return self.failure.save(err);
}

pub fn emitRxState(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    compiler.zig.state.append(&self.bundle.?, .{
        .analysis = &self.prepared.?.analysis,
        .cache = self.generationCache(),
    }) catch |err| return self.failure.save(err);

    self.closeStore();
}

pub fn reportRxApplicationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    cache.report(&self.cache.?, self.context.options, self.context.stderr) catch |err| return self.failure.save(err);
}

pub fn resolveRxToolchain(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    self.paths = toolchain.resolve(context.io, context.allocator, context.environment) catch |err| return self.reportFailure(err);

    return true;
}

pub fn resolveRxNativeProject(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const bundle = &self.bundle.?;

    self.native_project = @import("../standard.zig").resolve(self.context.allocator, self.loaded, bundle.native_modules.import_names, self.paths.standard, bundle.modules) catch |err| return self.failure.save(err);
}

pub fn runRxBackend(handle: *const anyopaque) Error!native.RxStatus {
    const self = State.get(handle);
    const result = native.run(self.context, &self.bundle.?, &self.native_project, self.paths) catch |err| return self.failure.save(err);

    return native.sourceStatusAs(native.RxStatus, result);
}
