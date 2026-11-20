const std = @import("std");
const builtin = @import("builtin");
const Inputs = @import("watch_inputs").Inputs;
const source = @import("manifest/input.zig");
const workspace = @import("workspace.zig");
const rules = @import("cli_source");
const constants = rules.workspace_constants.@"zx.constants";
const effects = @import("../cli/sources/effects.zig");
const Error = effects.Error;
pub const Probe = @import("package_workspace_abi").native.@"zig:package_workspace_host".Probe;

pub const Result = struct {
    path: ?[]const u8 = null,
    root: ?source.Known = null,
    members: ?workspace.Result = null,
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        if (self.members) |*members| members.deinit();
    }
};

const Candidate = struct {
    manifest: source.Known,
    arena: std.heap.ArenaAllocator,
};

const State = struct {
    io: std.Io,
    scratch: std.mem.Allocator,
    retained: std.mem.Allocator,
    entry: []const u8,
    inputs: ?*Inputs,
    directory: []const u8 = undefined,
    result: Result = .{},
    nearest: ?Candidate = null,
    candidate: ?Candidate = null,
    members: ?workspace.Result = null,
    member_memory: ?std.heap.ArenaAllocator = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn discardProbe(self: *State) void {
        if (self.members) |*members| members.deinit();
        if (self.member_memory) |*arena| arena.deinit();
        if (self.candidate) |*candidate| candidate.arena.deinit();

        self.members = null;
        self.member_memory = null;
        self.candidate = null;
    }
};

/// The compilation allocator owns accepted manifests. The workspace result owns the walk metadata.
pub fn findWithInputs(io: std.Io, scratch: std.mem.Allocator, retained: std.mem.Allocator, entry: []const u8, inputs: ?*Inputs) !Result {
    var state: State = .{
        .io = io,
        .scratch = scratch,
        .retained = retained,
        .entry = entry,
        .inputs = inputs,
    };

    defer {
        state.discardProbe();

        if (state.nearest) |*saved| saved.arena.deinit();
    }

    const reference = &state;

    rules.workspace_discover.executeValue(scratch, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return state.result;
}

pub fn startSearch(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    if (self.inputs) |observed| observed.add(self.io, self.entry) catch |err| return self.failure.save(err);

    const real = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.entry, self.scratch) catch |err| return self.failure.save(err);

    self.directory = std.fs.path.dirname(real).?;
}

pub fn readCandidate(handle: *const anyopaque) Error!Probe {
    const self = State.get(handle);
    const path = std.fs.path.join(self.scratch, &.{ self.directory, constants.manifest_name }) catch |err| return self.failure.save(err);

    const file = source.locate(self.io, self.scratch, path, self.inputs) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        else => return self.failure.save(err),
    };

    var arena = std.heap.ArenaAllocator.init(self.retained);
    var retained = false;

    defer if (!retained) arena.deinit();

    const parsed = source.decode(self.io, arena.allocator(), file, self.inputs) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        else => return self.failure.save(err),
    };

    switch (parsed) {
        .diagnostic => |issue| {
            self.result.diagnostic = source.diagnostic(self.scratch, path, issue) catch |err| return self.failure.save(err);

            return .Invalid;
        },
        .data => |data| {
            self.candidate = .{ .manifest = .{ .file = file, .data = data }, .arena = arena };
            retained = true;

            return .Read;
        },
    }
}

pub fn hasNearest(handle: *const anyopaque) bool {
    return State.get(handle).nearest != null;
}

pub fn hasWorkspace(handle: *const anyopaque) bool {
    return State.get(handle).candidate.?.manifest.data.workspace != null;
}

pub fn rememberCandidate(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.nearest = self.candidate;
    self.candidate = null;
}

pub fn selectCandidate(handle: *const anyopaque) void {
    const self = State.get(handle);
    const candidate = self.candidate.?.manifest;
    self.result.path = candidate.file.path;
    self.result.root = candidate;
    self.candidate = null;
}

pub fn loadAncestor(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const candidate = self.candidate.?.manifest;
    self.member_memory = .init(self.retained);

    self.members = workspace.loadPrepared(self.io, std.heap.smp_allocator, .{
        .path = candidate.file.path,
        .inputs = self.inputs,
        .manifests = self.member_memory.?.allocator(),
        .root = candidate,
        .member = self.nearest.?.manifest,
    }) catch |err| return self.failure.save(err);

    if (self.members.?.diagnostic) |message| {
        self.result.diagnostic = self.scratch.dupe(u8, message) catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

pub fn ancestorContainsMember(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const directory = self.directory;
    const local = std.fs.path.dirname(self.nearest.?.manifest.file.path).?;
    const target = std.fs.path.relative(self.scratch, directory, null, directory, local) catch |err| return self.failure.save(err);

    const member = if (comptime builtin.os.tag == .windows)
        workspace.portablePath(self.scratch, target) catch |err| return self.failure.save(err)

    else
        target;

    return workspace.containsMember(self.members.?.packages, member);
}

pub fn selectAncestor(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.result.path = self.candidate.?.manifest.file.path;
    self.result.members = self.members;
    self.members = null;
    self.member_memory = null;
    self.candidate = null;
    self.nearest = null;
}

pub fn moveParent(handle: *const anyopaque) bool {
    const self = State.get(handle);

    self.discardProbe();

    self.directory = std.fs.path.dirname(self.directory) orelse return false;

    return true;
}

pub fn selectNearest(handle: *const anyopaque) void {
    const self = State.get(handle);

    if (self.nearest) |saved| {
        self.result.path = saved.manifest.file.path;
        self.result.root = saved.manifest;
        self.nearest = null;
    }
}
