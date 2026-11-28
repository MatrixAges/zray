const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const native = @import("../build/native.zig");
const Error = @import("../sources/effects.zig").Error;
const State = @import("state.zig").State;
const Text = @import("cli_abi").layouts.@"zig:compilation_host".CompilationText;
const generation = @import("../generation_cache.zig");
const verification = @import("../verify.zig");

pub fn writeCompilationDiagnostic(handle: *const anyopaque, message: []const u8) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll(message) catch |err| return self.failure.save(err);
}

pub fn loadCompilationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    @import("../cache.zig").load(self) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.context.stderr.print("zxc cache read: {s}\n", .{@errorName(err)}) catch |issue| return self.failure.save(issue);
    };
}

pub fn saveCompilationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    @import("../cache.zig").save(self) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.context.stderr.print("zxc cache write: {s}\n", .{@errorName(err)}) catch |issue| return self.failure.save(issue);
    };
}

pub fn reportCompilationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.storage.?.report(&self.semantic.?, self.context.stderr) catch |err| return self.failure.save(err);
}

pub fn analyzeCompilation(handle: *const anyopaque, cache: bool) Error!?[]const u8 {
    const self = State.get(handle);
    const allocator = self.context.allocator;

    self.analyzed = if (cache)
        compiler.analyzeProjectIncremental(allocator, self.sources, self.loaded.project, &self.semantic.?) catch |err| return self.failure.save(err)

    else
        compiler.analyzeProjectWithCache(allocator, self.sources, self.loaded.project, &self.semantic.?.parse_cache) catch |err| return self.failure.save(err);

    const result = &self.analyzed.?.value;

    return if (result.* == .diagnostic) result.diagnostic.message else null;
}

pub fn verifyCompilationProgram(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    defer closeAnalysis(self);

    const options = self.options();

    return compiler.verification.check(self.context.io, verification.workspace_allocator, self.analyzed.?.value.ir, self.sources, self.loaded.project.entry, .{ .solver = options.solver, .output = options.output }, self.context.stderr) catch |err| self.failure.save(err);
}

pub fn generateCompilationFpga(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    defer closeAnalysis(self);

    return @import("../fpga.zig").runProgram(self.context, &self.analyzed.?.value.ir, self.sources, self.loaded.project.entry) catch |err| self.failure.save(err);
}

fn closeAnalysis(self: *State) void {
    self.analyzed.?.deinit();

    self.analyzed = null;
}

pub fn flushCompilationDiagnostics(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.flush() catch |err| return self.failure.save(err);
}

pub fn openCompilationGeneration(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.generation = generation.init(self.context.io, self.context.allocator, self.loaded.project.root_dir) catch |err| return self.failure.save(err);
}

fn configuration(self: *State) compiler.CompileOptions {
    const context = &self.context;
    const options = self.options();

    return .{
        .io = context.io,
        .concurrent_analysis = context.concurrent_analysis,
        .sources = self.sources,
        .project = self.loaded.project,
        .parse_cache = if (options.cache) null else &self.semantic.?.parse_cache,
        .semantic_cache = if (options.cache) &self.semantic.? else null,
        .generation_cache = if (options.native and options.cache) &self.generation.? else null,
        .solver = options.solver,
        .verification_allocator = verification.workspace_allocator,
        .writer = context.stderr,
        .type_output = if (options.output != null) &self.abi.writer else null,
    };
}

fn report(self: *State, issue: compiler.Diagnostic) Error!bool {
    defer issue.deinit();

    const source = if (issue.source_index) |index| self.sources[index].original orelse self.sources[index].source else self.source.?;
    const path = if (issue.source_index) |index| self.sources[index].path else self.options().input;
    const location = zx.source.locate(source, issue.span.start);
    const writer = self.context.stderr;

    writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ path, location.line, location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);
    writer.flush() catch |err| return self.failure.save(err);

    return false;
}

fn acceptText(self: *State, result: compiler.Result) Error!?*const Text {
    if (result == .diagnostic) {
        _ = try report(self, result.diagnostic);

        return null;
    }

    self.text = result.source;

    self.text_view = .{
        .source = result.source,
        .abi = self.abi.written(),
        .input_path = self.options().input,
        .original = self.source.?,
    };

    return &self.text_view;
}

pub fn formatCompilationSource(handle: *const anyopaque) Error!?*const Text {
    const self = State.get(handle);
    const result = compiler.format(self.context.allocator, self.source.?, self.options().input) catch |err| return self.failure.save(err);

    return acceptText(self, result);
}

pub fn emitCompilationText(handle: *const anyopaque) Error!?*const Text {
    const self = State.get(handle);
    const result = compiler.compileProjectVerified(self.context.allocator, configuration(self)) catch |err| return self.failure.save(err);

    return acceptText(self, result);
}

pub fn emitCompilationModules(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const result = compiler.compileProjectModulesVerified(self.context.allocator, configuration(self)) catch |err| return self.failure.save(err);

    if (result == .diagnostic) return report(self, result.diagnostic);

    self.bundle = result.bundle;

    return true;
}

pub fn reportCompilationGeneration(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    generation.report(&self.generation.?, self.options().*, self.context.stderr) catch |err| return self.failure.save(err);
}

pub fn resolveCompilationToolchain(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = &self.context;
    const writer = context.stderr;

    self.paths = @import("../toolchain.zig").resolve(context.io, context.allocator, context.environment) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return self.failure.save(err);

        writer.print("zxc toolchain cache: {s}\n", .{@errorName(err)}) catch |issue| return self.failure.save(issue);

        if (err == error.ZxcZigRequired) writer.writeAll("this zxc does not embed Zig; set ZXC_ZIG to a Zig " ++ @import("bundle").zig_version ++ " executable\n") catch |issue| return self.failure.save(issue);

        writer.flush() catch |issue| return self.failure.save(issue);

        return false;
    };

    return true;
}

pub fn buildCompilationModules(handle: *const anyopaque) Error!native.CompilationStatus {
    const self = State.get(handle);
    const bundle = &self.bundle.?;
    const project = @import("../standard.zig").resolve(self.context.allocator, self.loaded, bundle.native_modules.import_names, self.paths.standard, bundle.modules) catch |err| return self.failure.save(err);
    const result = native.run(&self.context, bundle, &project, self.paths) catch |err| return self.failure.save(err);

    return native.sourceStatusAs(native.CompilationStatus, result);
}
