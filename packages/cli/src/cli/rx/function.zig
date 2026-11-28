const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const project = @import("../project.zig");
const sources = @import("../sources.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const rx = @import("rx");
const named = @import("rx_analysis").call.named;
const Libraries = @import("../library/inputs.zig");
const SignatureCheck = @import("cli_abi").layouts.@"zig:rx_checking_host".SignatureCheck;

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    config_path: ?[]const u8,
    calls: []const Selection,
    writer: *std.Io.Writer,
    loaded: project.Loaded = undefined,
    cache: compiler.project.ParseCache,
    libraries: Libraries,
    detected: sources.Detected = undefined,
    signed: ?compiler.project.signature_project.Result = null,
    deferred_buffer: [1][]const u8 = undefined,
    signature_check: SignatureCheck = undefined,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn closeSignatures(self: *State) void {
        if (self.signed) |*result| result.deinit();

        self.signed = null;
    }

    fn deinit(self: *State) void {
        self.closeSignatures();
        self.libraries.deinit();
        self.cache.deinit();
    }
};

pub fn validate(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, config_path: ?[]const u8, modules: []const rx.ModuleSource, calls: []const Selection, writer: *std.Io.Writer) !bool {
    var state: State = .{
        .io = io,
        .allocator = allocator,
        .path = path,
        .source = source,
        .config_path = config_path,
        .calls = calls,
        .writer = writer,
        .cache = .{ .allocator = allocator },
        .libraries = .{ .allocator = allocator },
    };

    const reference = &state;
    const module_paths = zx.memory.borrowTextColumn("path", modules);

    defer state.deinit();

    return @import("cli_source").check_zx_function.executeIn(allocator, &.{
        .check = @ptrCast(&reference),
        .has_calls = calls.len != 0,
        .module_paths = @ptrCast(&module_paths),
        .module_count = modules.len,
    }) catch |err| state.failure.unwrap(err);
}

pub fn loadFunctionProject(handle: *const anyopaque) Error!?[]const u8 {
    const self = State.get(handle);

    self.loaded = project.load(self.io, self.allocator, self.path, self.config_path) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.writer.print("{s}: {s}\n", .{ self.config_path orelse "pkg.yaml", @errorName(err) }) catch |issue| return self.failure.save(issue);

        return null;
    };

    if (self.loaded.diagnostic) |message| {
        self.writer.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return null;
    }

    return self.loaded.project.root_dir;
}

pub fn loadFunctionSources(handle: *const anyopaque) Error!?bool {
    const self = State.get(handle);

    self.detected = sources.readDetectingRx(self.io, self.allocator, self.source, self.loaded.project, &self.cache, null, &self.libraries) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.writer.print("{s}: source loading: {s}\n", .{ self.path, @errorName(err) }) catch |issue| return self.failure.save(issue);

        return null;
    };

    self.loaded.project.compiled_libraries = self.libraries.libraries.items;

    return self.detected.has_rx;
}

pub fn analyzeFunctionSignatures(handle: *const anyopaque) Error!*const SignatureCheck {
    const self = State.get(handle);
    const inputs = self.detected.sources;
    self.signed = compiler.project.analyzeSignaturesWithCache(self.allocator, inputs, &.{self.path}, self.loaded.project, &self.cache) catch |err| return self.failure.save(err);

    const result = &self.signed.?.value;

    if (result.* == .diagnostic) {
        _ = report(self.writer, inputs, result.diagnostic) catch |err| return self.failure.save(err);
        self.signature_check = .{ .valid = false, .default_call = false, .deferred_sources = &.{} };

        return &self.signature_check;
    }

    const checked = named.inspect(self.calls, result.data.modules, self.path);

    if (checked.rejected) |index| {
        _ = rejectNamed(self.writer, self.calls[@intCast(index)]) catch |err| return self.failure.save(err);
        self.signature_check = .{ .valid = false, .default_call = false, .deferred_sources = &.{} };

        return &self.signature_check;
    }

    var found = false;

    if (checked.default_call) {
        for (result.data.modules) |module| {
            if (module.signature.has_deferred_source) {
                self.deferred_buffer[0] = module.signature.deferred_source;
                found = true;

                break;
            }
        }
    }

    self.signature_check = .{
        .valid = true,
        .default_call = checked.default_call,
        .deferred_sources = if (found) &self.deferred_buffer else &.{},
    };

    return &self.signature_check;
}

pub fn reportFunctionDelegate(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.writer.print("{s}: default re-export target is missing from the RX module collection\n", .{self.path}) catch |err| return self.failure.save(err);
}

pub fn analyzeCheckedFunction(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.closeSignatures();

    const inputs = self.detected.sources;
    var analyzed = compiler.analyzeProjectWithCache(self.allocator, inputs, self.loaded.project, &self.cache) catch |err| return self.failure.save(err);

    defer analyzed.deinit();

    if (analyzed.value == .diagnostic) return report(self.writer, inputs, analyzed.value.diagnostic) catch |err| return self.failure.save(err);

    const checked = named.inspect(self.calls, analyzed.modules, self.path);

    if (checked.rejected) |index| return rejectNamed(self.writer, self.calls[@intCast(index)]) catch |err| return self.failure.save(err);

    if (checked.default_call and analyzed.value.ir.type_only) {
        self.writer.print("{s}: Call.fn requires an executable ZX module with a default function\n", .{self.path}) catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

fn report(writer: *std.Io.Writer, inputs: []const compiler.project.Source, issue: anytype) !bool {
    const index = issue.source_index orelse 0;
    const location = zx.source.locate(inputs[index].original orelse inputs[index].source, issue.span.start);

    try writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ inputs[index].path, location.line, location.column, issue.code, issue.message });

    return false;
}

pub const Selection = struct { owner: []const u8, location: @import("rx").ast.Location, member: ?[]const u8 };

fn rejectNamed(writer: *std.Io.Writer, call: Selection) !bool {
    try writer.print("{s}:{d}:{d}: module: ZX source does not export the selected callable function '{s}'\n", .{ call.owner, call.location.line, call.location.column, call.member.? });

    return false;
}
