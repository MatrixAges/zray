const std = @import("std");
const builtin = @import("builtin");
const Inputs = @import("watch_inputs").Inputs;
const source = @import("manifest/input.zig");
const workspace = @import("workspace.zig");
const rules = @import("cli_source");
const constants = rules.workspace_constants.@"zx.constants";
const effects = @import("../cli/sources/effects.zig");
const Error = effects.Error;
const MemberSearch = @import("cli_abi").layouts.@"zig:package_workspace_host".MemberSearch;
pub const Probe = @import("cli_abi").native.@"zig:package_workspace_host".Probe;

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
    inputs: ?*Inputs,
    result: Result = .{},
    nearest: ?Candidate = null,
    candidate: ?Candidate = null,
    members: ?workspace.Result = null,
    member_memory: ?std.heap.ArenaAllocator = null,
    member_search: MemberSearch = undefined,
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
        .inputs = inputs,
    };

    defer {
        state.discardProbe();

        if (state.nearest) |*saved| saved.arena.deinit();
    }

    if (inputs) |observed| try observed.add(io, entry);

    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, entry, scratch);
    const reference = &state;

    const progress = rules.workspace_discover.executeIn(scratch, &.{
        .search = @ptrCast(&reference),
        .directory = std.fs.path.dirname(real).?,
    }) catch |err| return state.failure.unwrap(err);

    switch (progress) {
        .Current => selectCandidate(&state, &state.candidate),
        .Nearest => selectCandidate(&state, &state.nearest),
        .Ancestor => selectAncestor(&state),
        .Advance, .Stop => {},
        .Retained => unreachable,
    }

    return state.result;
}

pub fn readCandidate(handle: *const anyopaque, directory: []const u8) Error!Probe {
    const self = State.get(handle);

    self.discardProbe();

    const path = std.fs.path.join(self.scratch, &.{ directory, constants.manifest_name }) catch |err| return self.failure.save(err);

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

            return if (data.workspace == null) .Package else .Workspace;
        },
    }
}

pub fn rememberCandidate(handle: *const anyopaque) void {
    const self = State.get(handle);

    self.nearest = self.candidate;
    self.candidate = null;
}

fn selectCandidate(self: *State, selected: *?Candidate) void {
    const manifest = selected.*.?.manifest;
    self.result.path = manifest.file.path;
    self.result.root = manifest;
    selected.* = null;
}

pub fn loadAncestor(handle: *const anyopaque, directory: []const u8) Error!?*const MemberSearch {
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

        return null;
    }

    const local = std.fs.path.dirname(self.nearest.?.manifest.file.path).?;
    const target = std.fs.path.relative(self.scratch, directory, null, directory, local) catch |err| return self.failure.save(err);

    const member = if (comptime builtin.os.tag == .windows)
        workspace.portablePath(self.scratch, target) catch |err| return self.failure.save(err)

    else
        target;

    const packages = self.members.?.packages;
    const paths = self.scratch.alloc([]const u8, packages.len) catch |err| return self.failure.save(err);

    for (packages, 0..) |package, index| {
        paths[index] = package.path;
    }

    self.member_search = .{ .paths = paths, .target = member };

    return &self.member_search;
}

fn selectAncestor(self: *State) void {
    self.result.path = self.candidate.?.manifest.file.path;
    self.result.members = self.members;
    self.members = null;
    self.member_memory = null;
    self.candidate = null;
    self.nearest = null;
}
