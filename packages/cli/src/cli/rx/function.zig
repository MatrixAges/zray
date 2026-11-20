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

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    config_path: ?[]const u8,
    modules: []const rx.ModuleSource,
    calls: []const Selection,
    writer: *std.Io.Writer,
    loaded: project.Loaded = undefined,
    cache: compiler.project.ParseCache,
    libraries: Libraries,
    detected: sources.Detected = undefined,
    signed: ?compiler.project.signature_project.Result = null,
    default_call: bool = undefined,
    delegated: []const u8 = undefined,
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
        .modules = modules,
        .calls = calls,
        .writer = writer,
        .cache = .{ .allocator = allocator },
        .libraries = .{ .allocator = allocator },
    };

    const reference = &state;

    defer state.deinit();

    return @import("cli_source").check_zx_function.executeIn(allocator, @ptrCast(&reference)) catch |err| state.failure.unwrap(err);
}

pub fn loadFunctionProject(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.loaded = project.load(self.io, self.allocator, self.path, self.config_path) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.writer.print("{s}: {s}\n", .{ self.config_path orelse "pkg.yaml", @errorName(err) }) catch |issue| return self.failure.save(issue);

        return false;
    };

    if (self.loaded.diagnostic) |message| {
        self.writer.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

pub fn loadFunctionSources(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.detected = sources.readDetectingRx(self.io, self.allocator, self.source, self.loaded.project, &self.cache, null, &self.libraries) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.writer.print("{s}: source loading: {s}\n", .{ self.path, @errorName(err) }) catch |issue| return self.failure.save(issue);

        return false;
    };

    self.loaded.project.compiled_libraries = self.libraries.libraries.items;

    return true;
}

pub fn functionHasCalls(handle: *const anyopaque) bool {
    return State.get(handle).calls.len != 0;
}

pub fn functionHasRx(handle: *const anyopaque) bool {
    return State.get(handle).detected.has_rx;
}

pub fn analyzeFunctionSignatures(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const inputs = self.detected.sources;
    self.signed = compiler.project.analyzeSignaturesWithCache(self.allocator, inputs, &.{self.path}, self.loaded.project, &self.cache) catch |err| return self.failure.save(err);

    const result = &self.signed.?.value;

    if (result.* == .diagnostic) return report(self.writer, inputs, result.diagnostic) catch |err| return self.failure.save(err);

    const checked = named.inspect(self.calls, result.data.modules, self.path);

    if (checked.rejected) |index| return rejectNamed(self.writer, self.calls[@intCast(index)]) catch |err| return self.failure.save(err);

    self.default_call = checked.default_call;

    return true;
}

pub fn functionHasDefaultCall(handle: *const anyopaque) bool {
    return State.get(handle).default_call;
}

pub fn signatureModuleCount(handle: *const anyopaque) u64 {
    return State.get(handle).signed.?.value.data.modules.len;
}

pub fn selectFunctionDelegate(handle: *const anyopaque, index: u64) bool {
    const self = State.get(handle);
    const signature = &self.signed.?.value.data.modules[@intCast(index)].signature;

    if (!signature.has_deferred_source) return false;

    self.delegated = signature.deferred_source;

    return true;
}

pub fn functionModuleCount(handle: *const anyopaque) u64 {
    return State.get(handle).modules.len;
}

pub fn matchesFunctionDelegate(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const allocator = self.allocator;
    const absolute = std.fs.path.resolve(allocator, &.{ self.loaded.project.root_dir, self.modules[@intCast(index)].path }) catch |err| return self.failure.save(err);

    defer allocator.free(absolute);

    return std.mem.eql(u8, self.delegated, absolute);
}

pub fn reportFunctionDelegate(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.writer.print("{s}: default re-export target is missing from the RX module collection\n", .{self.path}) catch |err| return self.failure.save(err);
}

pub fn closeFunctionSignatures(handle: *const anyopaque) void {
    State.get(handle).closeSignatures();
}

pub fn analyzeCheckedFunction(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
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

pub const CallIndex = struct {
    const DependencyGraph = @import("rx_analysis").project.source_graph;

    graph: *const DependencyGraph.Graph,
    modules: []const @import("rx").ModuleSource,
    calls: []std.ArrayList(Selection),
    row: usize = undefined,
    references: []const @import("rx").dependency_reference.Entry = &.{},
    reference: @import("rx").dependency_reference.Entry = undefined,
    pub fn selectModule(self: *CallIndex, row: usize) usize {
        self.row = row;
        self.references = self.modules[row].indexedReferences() orelse unreachable;

        return self.edges().len;
    }

    fn edges(self: *const CallIndex) @TypeOf(self.graph.modules.items(.dependencies)[0]) {
        return self.graph.modules.items(.dependencies)[self.graph.sources.zx_count + self.row];
    }
    pub fn isCall(self: *const CallIndex, index: usize) bool {
        return self.edges()[index].reference == .call;
    }
    pub fn takeReference(self: *CallIndex) bool {
        const last = self.references.len - 1;
        const reference = self.references[last];
        self.references = self.references[0..last];

        if (reference.role != .Call) return false;

        self.reference = reference;

        return true;
    }
    pub fn record(self: *const CallIndex, allocator: std.mem.Allocator, index: usize) !void {
        if (self.reference.target != .Function) return;

        const edge = self.edges()[index];
        const attribute = self.reference.attribute.?;
        const member = if (edge.named) compiler.project.module_path.callMember(attribute.value).? else null;

        try self.calls[edge.target.source].append(allocator, .{ .owner = self.modules[self.row].path, .location = attribute.value_location, .member = member });
    }
};
