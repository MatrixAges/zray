const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const project = @import("../project.zig");
const sources = @import("../sources.zig");
const ProjectCheck = @import("load.zig").State;
const Error = @import("../sources/effects.zig").Error;
const named = @import("rx_analysis").call.named;
const Libraries = @import("../library/inputs.zig");
const SignatureCheck = @import("cli_abi").layouts.@"zig:rx_checking_host".SignatureCheck;

pub const Function = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    calls: []const Selection,
    loaded: project.Loaded = undefined,
    cache: compiler.project.ParseCache,
    libraries: Libraries,
    detected: sources.Detected = undefined,
    signed: ?compiler.project.signature_project.Result = null,
    deferred_buffer: [1][]const u8 = undefined,
    signature_check: SignatureCheck = undefined,
    fn closeSignatures(self: *Function) void {
        if (self.signed) |*result| result.deinit();

        self.signed = null;
    }

    pub fn deinit(self: *Function) void {
        self.closeSignatures();
        self.libraries.deinit();
        self.cache.deinit();
    }
    pub fn init(allocator: std.mem.Allocator, path: []const u8, source: []const u8, calls: []const Selection) Function {
        return .{
            .allocator = allocator,
            .path = path,
            .source = source,
            .calls = calls,
            .cache = .{ .allocator = allocator },
            .libraries = .{ .allocator = allocator },
        };
    }
};

pub fn loadFunctionProject(handle: *const anyopaque) Error!?[]const u8 {
    const check = ProjectCheck.get(handle);
    const self = &check.function.?;

    self.loaded = project.load(check.io, self.allocator, self.path, check.config_path) catch |err| {
        if (err == error.OutOfMemory) return check.failure.save(err);

        check.writer.print("{s}: {s}\n", .{ check.config_path orelse "pkg.yaml", @errorName(err) }) catch |issue| return check.failure.save(issue);

        return null;
    };

    if (self.loaded.diagnostic) |message| {
        check.writer.print("{s}\n", .{message}) catch |err| return check.failure.save(err);

        return null;
    }

    return self.loaded.project.root_dir;
}

pub fn loadFunctionSources(handle: *const anyopaque) Error!?bool {
    const check = ProjectCheck.get(handle);
    const self = &check.function.?;

    self.detected = sources.readDetectingRx(check.io, self.allocator, self.source, self.loaded.project, &self.cache, null, &self.libraries) catch |err| {
        if (err == error.OutOfMemory) return check.failure.save(err);

        check.writer.print("{s}: source loading: {s}\n", .{ self.path, @errorName(err) }) catch |issue| return check.failure.save(issue);

        return null;
    };

    self.loaded.project.compiled_libraries = self.libraries.libraries.items;

    return self.detected.has_rx;
}

pub fn analyzeFunctionSignatures(handle: *const anyopaque) Error!*const SignatureCheck {
    const check = ProjectCheck.get(handle);
    const self = &check.function.?;
    const inputs = self.detected.sources;
    self.signed = compiler.project.analyzeSignaturesWithCache(self.allocator, inputs, &.{self.path}, self.loaded.project, &self.cache) catch |err| return check.failure.save(err);

    const result = &self.signed.?.value;

    if (result.* == .diagnostic) {
        _ = report(check.writer, inputs, result.diagnostic) catch |err| return check.failure.save(err);
        self.signature_check = .{ .valid = false, .default_call = false, .deferred_sources = &.{} };

        return &self.signature_check;
    }

    const checked = named.inspect(self.calls, result.data.modules, self.path);

    if (checked.rejected) |index| {
        _ = rejectNamed(check.writer, self.calls[@intCast(index)]) catch |err| return check.failure.save(err);
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

pub fn analyzeCheckedFunction(handle: *const anyopaque) Error!bool {
    const check = ProjectCheck.get(handle);
    const self = &check.function.?;

    self.closeSignatures();

    const inputs = self.detected.sources;
    var analyzed = compiler.analyzeProjectWithCache(self.allocator, inputs, self.loaded.project, &self.cache) catch |err| return check.failure.save(err);

    defer analyzed.deinit();

    if (analyzed.value == .diagnostic) return report(check.writer, inputs, analyzed.value.diagnostic) catch |err| return check.failure.save(err);

    const checked = named.inspect(self.calls, analyzed.modules, self.path);

    if (checked.rejected) |index| return rejectNamed(check.writer, self.calls[@intCast(index)]) catch |err| return check.failure.save(err);

    if (checked.default_call and analyzed.value.ir.type_only) {
        check.writer.print("{s}: Call.fn requires an executable ZX module with a default function\n", .{self.path}) catch |err| return check.failure.save(err);

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

pub const Selection = @import("cli_abi").layouts.@"zig:rx_checking_host".SelectedCall;

fn rejectNamed(writer: *std.Io.Writer, call: Selection) !bool {
    try writer.print("{s}:{d}:{d}: module: ZX source does not export the selected callable function '{s}'\n", .{ call.owner, call.line, call.column, call.member.? });

    return false;
}
