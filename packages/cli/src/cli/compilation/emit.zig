const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const native = @import("../build/native.zig");
const Error = @import("../sources/effects.zig").Error;
const State = @import("state.zig").State;
const artifacts = @import("../artifacts.zig");
const generation = @import("../generation_cache.zig");
const verification = @import("../verify.zig");

pub fn compilationHasCompiledLibraries(handle: *const anyopaque) bool {
    return State.get(handle).loaded.project.compiled_libraries.len != 0;
}

pub fn reportCompilationCacheBypass(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll("zxc cache: compiled library inputs bypass semantic artifacts; parsing and generation caches remain available\n") catch |err| return self.failure.save(err);
}

pub fn loadCompilationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.storage.?.load(self.sources, self.loaded.project, &self.semantic.?) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.context.stderr.print("zxc cache read: {s}\n", .{@errorName(err)}) catch |issue| return self.failure.save(issue);
    };
}

pub fn saveCompilationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.storage.?.save(&self.semantic.?) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.context.stderr.print("zxc cache write: {s}\n", .{@errorName(err)}) catch |issue| return self.failure.save(issue);
    };
}

pub fn reportCompilationCache(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.storage.?.report(&self.semantic.?, self.context.stderr) catch |err| return self.failure.save(err);
}

pub fn reportCompilationCacheDisabled(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll("zxc cache: disabled\n") catch |err| return self.failure.save(err);
}

pub fn analyzeCompilationCached(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.analyzed = compiler.analyzeProjectIncremental(self.context.allocator, self.sources, self.loaded.project, &self.semantic.?) catch |err| return self.failure.save(err);
}

pub fn analyzeCompilationUncached(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.analyzed = compiler.analyzeProjectWithCache(self.context.allocator, self.sources, self.loaded.project, &self.semantic.?.parse_cache) catch |err| return self.failure.save(err);
}

pub fn checkCompilationAnalysis(handle: *const anyopaque, proof: bool) Error!bool {
    const self = State.get(handle);
    const result = &self.analyzed.?.value;

    if (result.* != .diagnostic) return true;

    self.context.stderr.print("{s}: {s}\n", .{ if (proof) "verification" else "fpga", result.diagnostic.message }) catch |err| return self.failure.save(err);

    return false;
}

pub fn verifyCompilationProgram(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const options = self.options();

    return compiler.verification.check(self.context.io, verification.workspace_allocator, self.analyzed.?.value.ir, self.sources, self.loaded.project.entry, .{ .solver = options.solver, .output = options.output }, self.context.stderr) catch |err| self.failure.save(err);
}

pub fn generateCompilationFpga(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    return @import("../fpga.zig").runProgram(self.context, &self.analyzed.?.value.ir, self.sources, self.loaded.project.entry) catch |err| self.failure.save(err);
}

pub fn closeCompilationAnalysis(handle: *const anyopaque) void {
    const self = State.get(handle);

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

fn acceptText(self: *State, result: compiler.Result) Error!bool {
    if (result == .diagnostic) return report(self, result.diagnostic);

    self.text = result.source;

    return true;
}

pub fn formatCompilationSource(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const result = compiler.format(self.context.allocator, self.source.?, self.options().input) catch |err| return self.failure.save(err);

    return acceptText(self, result);
}

pub fn emitCompilationText(handle: *const anyopaque) Error!bool {
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

pub fn buildCompilationModules(handle: *const anyopaque) Error!native.Status {
    const self = State.get(handle);
    const bundle = &self.bundle.?;
    const project = @import("../standard.zig").resolve(self.context.allocator, self.loaded, bundle.native_modules.import_names, self.paths.standard, bundle.modules) catch |err| return self.failure.save(err);
    const result = native.run(&self.context, bundle, &project, self.paths) catch |err| return self.failure.save(err);

    return native.sourceStatus(result);
}

pub fn checkCompilationText(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const writer = self.context.stderr;

    if (std.mem.eql(u8, self.source.?, self.text.?)) return true;

    writer.print("{s}: {s}\n", .{ self.options().input, @import("lint").source.formatting_required }) catch |err| return self.failure.save(err);
    writer.flush() catch |err| return self.failure.save(err);

    return false;
}

pub fn writeCompilationText(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = &self.context;
    const options = self.options();

    if (self.abi.written().len != 0) {
        const path = std.fmt.allocPrint(context.allocator, "{s}.abi.zig", .{options.output.?}) catch |err| return self.failure.save(err);

        artifacts.write(context.io, path, self.abi.written()) catch |err| return self.failure.save(err);
    }

    artifacts.write(context.io, if (options.write) options.input else options.output.?, self.text.?) catch |err| return self.failure.save(err);
}

pub fn printCompilationText(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stdout.writeAll(self.text.?) catch |err| return self.failure.save(err);
}
