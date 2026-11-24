const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const compiler = @import("compiler");
const source = @import("manifest/input.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const rules = @import("cli_source");
const effects = @import("../cli/sources/effects.zig");
const Error = effects.Error;
const Directory = @import("package_workspace_abi").layouts.@"zig:package_workspace_host".Directory;
const constants = rules.workspace_constants.@"zx.constants";
pub const Package = struct { path: []const u8, manifest: Manifest };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "",
    packages: []const Package = &.{},
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Result {
    return loadPrepared(io, allocator, .{ .path = path });
}

pub const Request = struct {
    path: []const u8,
    inputs: ?*Inputs = null,
    manifests: ?std.mem.Allocator = null,
    root: ?source.Known = null,
    member: ?source.Known = null,
};

pub fn loadPrepared(io: std.Io, allocator: std.mem.Allocator, request: Request) !Result {
    var result: Result = .{ .arena = .init(allocator) };

    errdefer result.deinit();

    if (request.inputs) |observed| try observed.add(io, request.path);

    result.packages = collect(io, &result, request) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}: {s}", .{ request.path, @errorName(err) });

        return result;
    };

    return result;
}

const State = struct {
    io: std.Io,
    result: *Result,
    request: Request,
    allocator: std.mem.Allocator,
    manifests: std.mem.Allocator,
    names_memory: std.heap.ArenaAllocator,
    failure: effects.Failure = .{},
    packages: std.ArrayList(Package) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
    names: compiler.project.source_index.Owned = .{},
    directory: ?std.Io.Dir = null,
    walker: ?std.Io.Dir.SelectiveWalker = null,
    current: std.Io.Dir.Walker.Entry = undefined,
    current_view: Directory = undefined,
    member: Manifest = undefined,
    member_path: []const u8 = undefined,
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn closeDirectory(self: *State) void {
        if (self.walker) |*walker| {
            while (walker.stack.items.len > 0) walker.leave(self.io);

            walker.deinit();

            self.walker = null;
        }

        if (self.directory) |dir| {
            dir.close(self.io);

            self.directory = null;
        }
    }
};

fn collect(io: std.Io, result: *Result, request: Request) ![]const Package {
    const allocator = result.arena.allocator();

    var state: State = .{
        .io = io,
        .result = result,
        .request = request,
        .allocator = allocator,
        .manifests = request.manifests orelse allocator,
        .names_memory = .init(result.arena.child_allocator),
    };

    defer state.names_memory.deinit();
    defer state.closeDirectory();

    const reference = &state;

    rules.workspace_collect.executeIn(allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return try state.packages.toOwnedSlice(allocator);
}

pub fn readRoot(handle: *const anyopaque) Error![]const []const u8 {
    const self = State.get(handle);
    const path = self.request.path;
    const parent = std.fs.path.dirname(path) orelse constants.root_path;
    self.result.root = std.Io.Dir.cwd().realPathFileAlloc(self.io, parent, self.allocator) catch |err| return self.failure.save(err);

    const data = read(self.io, self.result, path, self.request.inputs, self.manifests, self.request.root) catch |err| return self.failure.save(err);

    self.packages.append(self.allocator, .{ .path = constants.root_path, .manifest = data }) catch |err| return self.failure.save(err);

    return if (data.workspace) |workspace| workspace.packages else &.{};
}

pub fn invalidPattern(handle: *const anyopaque, pattern: []const u8) Error!void {
    const self = State.get(handle);

    self.result.diagnostic = std.fmt.allocPrint(self.allocator, "{s}: unsupported workspace pattern: {s}", .{ self.request.path, pattern }) catch |err| return self.failure.save(err);

    return self.failure.save(error.InvalidWorkspace);
}

pub fn openDirectory(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const root = self.result.root;

    if (self.request.inputs) |observed| observed.add(self.io, root) catch |err| return self.failure.save(err);

    const dir = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch |err| return self.failure.save(err);

    self.directory = dir;
    self.walker = dir.walkSelectively(self.allocator) catch |err| return self.failure.save(err);
}

pub fn nextDirectory(handle: *const anyopaque) Error!?*const Directory {
    const self = State.get(handle);
    const walker = &self.walker.?;

    while (walker.next(self.io) catch |err| return self.failure.save(err)) |entry| {
        if (entry.kind != .directory) continue;

        self.current = entry;
        self.current_view = .{ .path = entry.path, .name = entry.basename };

        return &self.current_view;
    }

    return null;
}

pub fn recordDirectory(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const path = self.allocator.dupe(u8, self.current.path) catch |err| return self.failure.save(err);

    self.paths.append(self.allocator, path) catch |err| return self.failure.save(err);
}

pub fn enterDirectory(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    if (self.request.inputs) |observed| {
        const child = std.fs.path.join(self.allocator, &.{ self.result.root, self.current.path }) catch |err| return self.failure.save(err);

        observed.add(self.io, child) catch |err| return self.failure.save(err);
    }

    self.walker.?.enter(self.io, self.current) catch |err| return self.failure.save(err);
}

pub fn orderMembers(handle: *const anyopaque) Error!u64 {
    const self = State.get(handle);

    self.closeDirectory();
    std.mem.sort([]const u8, self.paths.items, {}, lessThan);

    _ = self.names.register(self.names_memory.allocator(), self.packages.items[0].manifest.name, 0) catch |err| return self.failure.save(err);

    return self.paths.items.len;
}

pub fn readMember(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const member = self.paths.items[@intCast(index)];
    const path = std.fs.path.join(self.allocator, &.{ self.result.root, member, constants.manifest_name }) catch |err| return self.failure.save(err);

    self.member_path = path;

    self.member = read(self.io, self.result, path, self.request.inputs, self.manifests, self.request.member) catch |err| {
        if (err == error.FileNotFound) return false;
        if (err == error.OutOfMemory) return self.failure.save(err);

        if (self.result.diagnostic == null) {
            self.result.diagnostic = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ path, @errorName(err) }) catch |failure| return self.failure.save(failure);
        }

        return self.failure.save(err);
    };

    return true;
}

pub fn registerMember(handle: *const anyopaque, index: u64) Error!?u64 {
    const self = State.get(handle);
    const previous = self.names.register(self.names_memory.allocator(), self.member.name, @intCast(index + 1)) catch |err| return self.failure.save(err);

    return if (previous) |row| row else null;
}

pub fn duplicateMember(handle: *const anyopaque, previous: u64) Error!void {
    const self = State.get(handle);
    const first = if (previous == 0) constants.root_path else self.paths.items[@intCast(previous - 1)];

    self.result.diagnostic = std.fmt.allocPrint(self.allocator, "{s}: duplicate workspace package {s}; first declared at {s}", .{ self.member_path, self.member.name, first }) catch |err| return self.failure.save(err);

    return self.failure.save(error.InvalidWorkspace);
}

pub fn publishMember(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const path = portablePath(self.allocator, self.paths.items[@intCast(index)]) catch |err| return self.failure.save(err);

    self.packages.append(self.allocator, .{ .path = path, .manifest = self.member }) catch |err| return self.failure.save(err);
}

fn read(io: std.Io, result: *Result, path: []const u8, inputs: ?*Inputs, manifests: std.mem.Allocator, known: ?source.Known) !Manifest {
    const allocator = result.arena.allocator();
    const file = try source.locate(io, allocator, path, inputs);
    const relative = try std.fs.path.relative(allocator, result.root, null, result.root, file.physical);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const within = rules.workspace_manifest_within.executeValue(scratch.allocator(), &.{
        .path = relative,
        .absolute = std.fs.path.isAbsolute(relative),
    }) catch unreachable;

    if (!within) {
        result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: manifest escapes the workspace root", .{path});

        return error.InvalidWorkspace;
    }

    if (known) |prepared| {
        if (prepared.matches(file)) return prepared.data;
    }

    return switch (try source.decode(io, manifests, file, inputs)) {
        .data => |data| data,
        .diagnostic => |issue| {
            result.diagnostic = try source.diagnostic(allocator, path, issue);

            return error.InvalidWorkspace;
        },
    };
}

pub fn portablePath(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return rules.workspace_portable_path.executeValue(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
