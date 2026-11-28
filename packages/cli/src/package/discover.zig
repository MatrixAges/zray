const std = @import("std");
const builtin = @import("builtin");
const Project = @import("project.zig").State;
const source = @import("manifest/input.zig");
const workspace = @import("workspace.zig");
const rules = @import("cli_source");
const Error = @import("../cli/sources/effects.zig").Error;
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

pub const Search = struct {
    result: Result = .{},
    nearest: ?Candidate = null,
    candidate: ?Candidate = null,
    members: ?workspace.Result = null,
    member_memory: ?std.heap.ArenaAllocator = null,
    member_search: MemberSearch = undefined,
    fn discardProbe(self: *Search) void {
        if (self.members) |*members| members.deinit();
        if (self.member_memory) |*arena| arena.deinit();
        if (self.candidate) |*candidate| candidate.arena.deinit();

        self.members = null;
        self.member_memory = null;
        self.candidate = null;
    }
};

/// The compilation allocator owns accepted manifests. The workspace result owns the walk metadata.
pub fn find(state: *Project) !Result {
    const search = &state.search;
    const reference = state;

    defer {
        search.discardProbe();

        if (search.nearest) |*saved| saved.arena.deinit();

        search.* = .{};
    }

    if (state.inputs) |observed| try observed.add(state.io, state.entry);

    const real = try std.Io.Dir.cwd().realPathFileAlloc(state.io, state.entry, state.scratch);

    const progress = rules.workspace_discover.executeIn(state.scratch, &.{
        .search = @ptrCast(&reference),
        .directory = std.fs.path.dirname(real).?,
    }) catch |err| return state.failure.unwrap(err);

    switch (progress) {
        .Current => selectCandidate(search, &search.candidate),
        .Nearest => selectCandidate(search, &search.nearest),
        .Ancestor => selectAncestor(search),
        .Advance, .Stop => {},
        .Retained => unreachable,
    }

    return search.result;
}

pub fn readCandidate(handle: *const anyopaque, path: []const u8) Error!Probe {
    const project = Project.get(handle);
    const self = &project.search;

    self.discardProbe();

    const file = source.locate(project.io, project.scratch, path, project.inputs) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        else => return project.failure.save(err),
    };

    var arena = std.heap.ArenaAllocator.init(project.allocator);
    var retained = false;

    defer if (!retained) arena.deinit();

    const parsed = source.decode(project.io, arena.allocator(), file, project.inputs) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        else => return project.failure.save(err),
    };

    switch (parsed) {
        .diagnostic => |issue| {
            self.result.diagnostic = source.diagnostic(project.scratch, path, issue) catch |err| return project.failure.save(err);

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
    const project = Project.get(handle);
    const self = &project.search;

    self.nearest = self.candidate;
    self.candidate = null;
}

fn selectCandidate(self: *Search, selected: *?Candidate) void {
    const manifest = selected.*.?.manifest;
    self.result.path = manifest.file.path;
    self.result.root = manifest;
    selected.* = null;
}

pub fn loadAncestor(handle: *const anyopaque, directory: []const u8) Error!?*const MemberSearch {
    const project = Project.get(handle);
    const self = &project.search;
    const candidate = self.candidate.?.manifest;
    self.member_memory = .init(project.allocator);

    self.members = workspace.loadPrepared(project.io, std.heap.smp_allocator, .{
        .path = candidate.file.path,
        .inputs = project.inputs,
        .manifests = self.member_memory.?.allocator(),
        .root = candidate,
        .member = self.nearest.?.manifest,
    }) catch |err| return project.failure.save(err);

    if (self.members.?.diagnostic) |message| {
        self.result.diagnostic = project.scratch.dupe(u8, message) catch |err| return project.failure.save(err);

        return null;
    }

    const local = std.fs.path.dirname(self.nearest.?.manifest.file.path).?;
    const target = std.fs.path.relative(project.scratch, directory, null, directory, local) catch |err| return project.failure.save(err);

    const member = if (comptime builtin.os.tag == .windows)
        workspace.portablePath(project.scratch, target) catch |err| return project.failure.save(err)

    else
        target;

    const packages = self.members.?.packages;
    const paths = project.scratch.alloc([]const u8, packages.len) catch |err| return project.failure.save(err);

    for (packages, 0..) |package, index| {
        paths[index] = package.path;
    }

    self.member_search = .{ .paths = paths, .target = member };

    return &self.member_search;
}

fn selectAncestor(self: *Search) void {
    self.result.path = self.candidate.?.manifest.file.path;
    self.result.members = self.members;
    self.members = null;
    self.member_memory = null;
    self.candidate = null;
    self.nearest = null;
}
